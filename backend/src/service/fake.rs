//! Explicit controlled exerciser only; no audio/model/native inference path.
use super::{LiveWorker, TICK, WorkerEvent, start_worker};
use crate::launcher::NetworkIsolation;
use std::io::{Read, Write};
use std::sync::mpsc::{self, Receiver, Sender};
use std::time::{Duration, Instant};

pub(super) fn action(value: Option<&str>) -> Option<u8> {
    Some(match value {
        None | Some("complete") => 0,
        Some("crash") => 1,
        Some("stall") => 2,
        Some("stale") => 3,
        Some("wrong_id") => 4,
        Some("oversized") => 5,
        Some("partial") => 6,
        Some("wrong_version") => 7,
        Some("diagnostic") => 8,
        Some("fragmented") => 9,
        Some("excess_bytes") => 10,
        _ => return None,
    })
}

pub(super) fn run(
    mode: NetworkIsolation,
    action: u8,
    cancelled: Receiver<()>,
    generation: u64,
    id: &str,
    warm: &mut Option<LiveWorker>,
    done: &Sender<WorkerEvent>,
) -> bool {
    if !matches!(cancelled.try_recv(), Err(mpsc::TryRecvError::Empty)) {
        return false;
    }
    if warm.is_none() {
        let Ok(child) = start_worker(mode, "hagig-fake-worker") else {
            return false;
        };
        *warm = Some(child);
    }
    let worker = warm.as_mut().unwrap();
    use rustix::fs::{OFlags, fcntl_setfl};
    if fcntl_setfl(&worker.pipes.output, OFlags::NONBLOCK).is_err()
        || fcntl_setfl(&worker.pipes.input, OFlags::NONBLOCK).is_err()
    {
        return false;
    }
    let expected = frame(generation, id, 1);
    let request = frame(generation, id, action);
    if worker.pipes.input.write_all(&request).is_err() {
        return false;
    }
    let deadline = Instant::now() + Duration::from_secs(120);
    let _ = done.send(WorkerEvent::Started(
        generation,
        worker
            .supervisor
            .child_id()
            .expect("successful start owns child"),
    ));
    let mut reply = Vec::with_capacity(expected.len());
    while Instant::now() < deadline
        && matches!(cancelled.try_recv(), Err(mpsc::TryRecvError::Empty))
    {
        // Read no more than the fixed maximum envelope; never trust a child length.
        let mut bytes = [0; 140];
        match worker.pipes.output.read(&mut bytes) {
            Ok(0) => return false,
            Ok(n) => {
                if reply.len() + n > expected.len() {
                    return false;
                }
                reply.extend_from_slice(&bytes[..n]);
                if !expected.starts_with(&reply) {
                    return false;
                }
                if reply.len() == expected.len() {
                    return true;
                }
                // At most 138 valid short prefixes per bounded envelope.
                let _ = done.send(WorkerEvent::Progress(generation, reply.len()));
            }
            Err(e)
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::Interrupted
                ) => {}
            Err(_) => return false,
        }
        std::thread::sleep(TICK);
    }
    false
}

// Private v1 envelope: version:u8, generation:u64 BE, id length:u8, opaque ID,
// action/result:u8. IDs are 1..128 ASCII token bytes; maximum wire size 139.
fn frame(generation: u64, id: &str, value: u8) -> Vec<u8> {
    let mut bytes = vec![1];
    bytes.extend_from_slice(&generation.to_be_bytes());
    bytes.push(id.len() as u8);
    bytes.extend_from_slice(id.as_bytes());
    bytes.push(value);
    bytes
}
