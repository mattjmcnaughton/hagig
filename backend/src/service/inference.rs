//! Server-side private inference exchange. No native code is linked or loaded.
use super::{InferenceSettings, LiveWorker, SafeResult, TICK, WorkerEvent, start_worker};
use crate::worker_protocol::{self, Reply, Request};
use rustix::fs::{OFlags, fcntl_setfl};
use std::io::{Read, Write};
use std::sync::mpsc::{self, Receiver, Sender};
use std::time::{Duration, Instant};

pub(super) fn run(
    settings: InferenceSettings,
    pcm: Vec<u8>,
    cancelled: Receiver<()>,
    generation: u64,
    id: &str,
    warm: &mut Option<LiveWorker>,
    done: &Sender<WorkerEvent>,
) -> SafeResult<String> {
    let deadline = Instant::now() + Duration::from_secs(120);
    crate::model::check_directory(&settings.model)?;
    if !matches!(cancelled.try_recv(), Err(mpsc::TryRecvError::Empty)) {
        return Err("worker_failed");
    }
    if warm.is_none() {
        *warm = Some(start_worker(
            settings.config.network_isolation(),
            "hagig-worker",
        )?);
    }
    let worker = warm.as_mut().unwrap();
    fcntl_setfl(&worker.pipes.output, OFlags::NONBLOCK).map_err(|_| "worker_failed")?;
    fcntl_setfl(&worker.pipes.input, OFlags::NONBLOCK).map_err(|_| "worker_failed")?;
    let _ = done.send(WorkerEvent::Started(
        generation,
        worker.supervisor.child_id().unwrap(),
    ));
    let request = Request {
        version: 1,
        generation,
        request_id: id.to_owned(),
        model: settings.model,
        hotwords: settings.config.hotwords().to_owned(),
        audio_bytes: pcm.len(),
    };
    let header = worker_protocol::encode(&request).map_err(|_| "worker_failed")?;
    // Send bounded header then PCM without combining another full audio copy.
    let mut part = 0;
    let mut offset = 0;
    let mut reply = Vec::new();
    let mut expected = None;
    while Instant::now() < deadline {
        if !matches!(cancelled.try_recv(), Err(mpsc::TryRecvError::Empty)) {
            return Err("worker_failed");
        }
        if part < 2 {
            let bytes = if part == 0 { &header } else { &pcm };
            match worker.pipes.input.write(&bytes[offset..]) {
                Ok(0) => return Err("worker_failed"),
                Ok(n) => {
                    offset += n;
                    if offset == bytes.len() {
                        part += 1;
                        offset = 0;
                    }
                }
                Err(e)
                    if matches!(
                        e.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::Interrupted
                    ) => {}
                Err(_) => return Err("worker_failed"),
            }
        }
        let mut bytes = [0; 8192];
        match worker.pipes.output.read(&mut bytes) {
            Ok(0) => return Err("worker_failed"),
            Ok(n) => {
                if part < 2 || reply.len() + n > worker_protocol::CONTROL + 5 {
                    return Err("worker_failed");
                }
                reply.extend_from_slice(&bytes[..n]);
                if reply.len() >= 5 && expected.is_none() {
                    let size = u32::from_be_bytes(reply[1..5].try_into().unwrap()) as usize;
                    if reply[0] != 1 || size > worker_protocol::CONTROL {
                        return Err("worker_failed");
                    }
                    expected = Some(size + 5);
                }
                if let Some(size) = expected {
                    if reply.len() > size {
                        return Err("worker_failed");
                    }
                    if reply.len() == size {
                        // A complete frame can end exactly at our read buffer
                        // boundary. EOF is not excess: terminal errors may be
                        // followed by exit and must retain their safe code.
                        loop {
                            match worker.pipes.output.read(&mut [0; 1]) {
                                Ok(0) => break,
                                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => break,
                                Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                                _ => return Err("worker_failed"),
                            }
                        }
                        let result: Reply =
                            serde_json::from_slice(&reply[5..]).map_err(|_| "worker_failed")?;
                        if result.version != 1
                            || result.generation != generation
                            || result.request_id != id
                        {
                            return Err("worker_failed");
                        }
                        return match (result.text, result.code.as_deref()) {
                            (Some(text), None) => Ok(text),
                            (None, Some("model_missing")) => Err("model_missing"),
                            (None, Some("model_invalid")) => Err("model_invalid"),
                            (None, Some("result_too_large")) => Err("result_too_large"),
                            _ => Err("worker_failed"),
                        };
                    }
                }
            }
            Err(e)
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::Interrupted
                ) => {}
            Err(_) => return Err("worker_failed"),
        }
        std::thread::sleep(TICK);
    }
    Err("deadline_exceeded")
}
