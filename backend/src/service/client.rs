//! File client, including finite transcript wait and cancellation before stdout.
use super::paths::{connect, runtime, validate};
use super::{AUDIO, CONTROL, InferenceSettings, SafeResult, TICK, packet, serve};
use crate::launcher::NetworkIsolation;
use serde::Deserialize;
use serde::de::{Error, MapAccess, SeqAccess, Visitor};
use serde_json::{Value, json};
use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU8, Ordering};
use std::time::{Duration, Instant};

// Value normally discards duplicate keys. Validate all objects, including
// unknown extension objects, while preserving additive server response fields.
struct Unique(Value);
impl<'de> Deserialize<'de> for Unique {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct Json;
        impl<'de> Visitor<'de> for Json {
            type Value = Unique;
            fn expecting(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                f.write_str("JSON without duplicate object keys")
            }
            fn visit_unit<E: Error>(self) -> Result<Unique, E> {
                Ok(Unique(Value::Null))
            }
            fn visit_bool<E: Error>(self, v: bool) -> Result<Unique, E> {
                Ok(Unique(v.into()))
            }
            fn visit_i64<E: Error>(self, v: i64) -> Result<Unique, E> {
                Ok(Unique(v.into()))
            }
            fn visit_u64<E: Error>(self, v: u64) -> Result<Unique, E> {
                Ok(Unique(v.into()))
            }
            fn visit_f64<E: Error>(self, v: f64) -> Result<Unique, E> {
                serde_json::Number::from_f64(v)
                    .map(|v| Unique(Value::Number(v)))
                    .ok_or_else(|| E::custom("invalid_number"))
            }
            fn visit_str<E: Error>(self, v: &str) -> Result<Unique, E> {
                Ok(Unique(v.into()))
            }
            fn visit_seq<A: SeqAccess<'de>>(self, mut a: A) -> Result<Unique, A::Error> {
                let mut values = Vec::new();
                while let Some(Unique(v)) = a.next_element()? {
                    values.push(v);
                }
                Ok(Unique(Value::Array(values)))
            }
            fn visit_map<A: MapAccess<'de>>(self, mut a: A) -> Result<Unique, A::Error> {
                let mut values = serde_json::Map::new();
                while let Some(key) = a.next_key::<String>()? {
                    if values.contains_key(&key) {
                        return Err(A::Error::custom("duplicate_key"));
                    }
                    let Unique(value) = a.next_value()?;
                    values.insert(key, value);
                }
                Ok(Unique(Value::Object(values)))
            }
        }
        deserializer.deserialize_any(Json)
    }
}

fn decode_json(bytes: &[u8]) -> SafeResult<Value> {
    serde_json::from_slice::<Unique>(bytes)
        .map(|v| v.0)
        .map_err(|_| "incompatible_protocol")
}

fn read_before(stream: &mut UnixStream, bytes: &mut [u8], deadline: Instant) -> SafeResult<()> {
    let mut offset = 0;
    while offset < bytes.len() {
        if interrupted() {
            return Err("interrupted");
        }
        if Instant::now() >= deadline {
            return Err("connection_timeout");
        }
        match stream.read(&mut bytes[offset..]) {
            Ok(0) => return Err("connection_read_eof"),
            Ok(n) => offset += n,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => (),
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => std::thread::sleep(TICK),
            Err(_) => return Err("connection_read_failed"),
        }
    }
    Ok(())
}

fn write_before(stream: &mut UnixStream, outgoing: &[u8], deadline: Instant) -> SafeResult<()> {
    let mut offset = 0;
    while offset < outgoing.len() {
        if interrupted() {
            return Err("interrupted");
        }
        if Instant::now() >= deadline {
            return Err("connection_timeout");
        }
        match stream.write(&outgoing[offset..]) {
            Ok(0) => return Err("connection_write_zero"),
            Ok(n) => offset += n,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => (),
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => std::thread::sleep(TICK),
            Err(_) => return Err("connection_write_failed"),
        }
    }
    Ok(())
}

fn exchange(stream: &mut UnixStream, kind: &str) -> SafeResult<Value> {
    let deadline = Instant::now() + Duration::from_secs(5);
    let value = if matches!(kind, "begin" | "end_audio") {
        json!({"version":1,"type":kind,"request_id":"cli"})
    } else {
        json!({"version":1,"type":kind})
    };
    write_before(stream, &packet(&value), deadline)?;
    let mut header = [0; 5];
    read_before(stream, &mut header, deadline)?;
    let len = u32::from_be_bytes(header[1..].try_into().unwrap()) as usize;
    if header[0] != 1 || len > CONTROL {
        return Err("incompatible_protocol");
    }
    let mut bytes = vec![0; len];
    read_before(stream, &mut bytes, deadline)?;
    decode_response(&bytes, kind)
}

fn decode_response(bytes: &[u8], kind: &str) -> SafeResult<Value> {
    let value = decode_json(bytes)?;
    if value["version"] != 1
        || (matches!(kind, "begin" | "end_audio") && value["request_id"] != "cli")
    {
        return Err("incompatible_protocol");
    }
    if value["type"] == "error" {
        return Err(match value["code"].as_str() {
            Some("busy") => "busy",
            Some("worker_failed") => "worker_failed",
            Some("deadline_exceeded") => "deadline_exceeded",
            Some("model_missing") => "model_missing",
            Some("model_invalid") => "model_invalid",
            Some("invalid_audio") => "invalid_audio",
            Some("result_too_large") => "result_too_large",
            Some("server_stopping") => "server_stopping",
            _ => "incompatible_protocol",
        });
    }
    let expected = match kind {
        "hello" => "hello_ok",
        "begin" => "accepted",
        "end_audio" => "result",
        "stop" => "stopped",
        _ => kind,
    };
    if value["type"] != expected {
        return Err("incompatible_protocol");
    }
    Ok(value)
}

// One CLI request per process. Cancellation and delivery initiation have a single
// atomic ordering: 0 live, 1 cancelled, 2 delivery initiated (cannot be undone).
static DELIVERY: AtomicU8 = AtomicU8::new(0);
pub(super) fn interrupted() -> bool {
    DELIVERY.load(Ordering::Relaxed) == 1
}

pub(super) fn install_interrupt_handler() -> SafeResult<()> {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_io()
        .build()
        .map_err(|_| "startup_failed")?;
    let entered = runtime.enter();
    let mut signal = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::interrupt())
        .map_err(|_| "startup_failed")?;
    drop(entered);
    std::thread::spawn(move || {
        runtime.block_on(signal.recv());
        let _ = DELIVERY.compare_exchange(0, 1, Ordering::Relaxed, Ordering::Relaxed);
    });
    Ok(())
}

fn capabilities(hello: &Value) -> bool {
    let manifest = crate::model::manifest();
    hello["worker"] == "inference"
        && hello["config_generation"]
            .as_str()
            .is_some_and(crate::worker_protocol::valid_id)
        && matches!(
            hello["network_isolation"].as_str(),
            Some("required" | "disabled")
        )
        && matches!(
            hello["settings"]["editor_mode"].as_str(),
            Some("standard" | "vim")
        )
        && hello["settings"]["model_id"] == manifest.id
        && hello["settings"]["model_revision"] == manifest.revision
        && hello["settings"]["language"] == "en"
        && hello["audio"] == json!({"encoding":"f32le","sample_rate_hz":16000,"channels":1})
        && hello["limits"]
            == json!({"control_bytes":65536,"audio_chunk_bytes":262144,"audio_total_bytes":19200000,"recording_seconds":300,"warning_seconds":285,"request_id_bytes":128})
        && hello["deadlines"]
            == json!({"control_seconds":5,"reservation_seconds":330,"computation_seconds":120})
}

pub(super) fn transcribe(stream: &mut UnixStream, hello: &Value, path: &Path) -> SafeResult<()> {
    if !capabilities(hello) {
        return Err("incompatible_protocol");
    }
    let accepted = exchange(stream, "begin")?;
    if accepted["config_generation"] != hello["config_generation"]
        || accepted["model_id"] != hello["settings"]["model_id"]
    {
        return Err("incompatible_protocol");
    }
    let reservation = Instant::now() + Duration::from_secs(330);
    let samples = crate::audio::read_wav(path)?;
    for samples in samples.chunks(AUDIO / 4) {
        let mut frame = vec![2];
        frame.extend_from_slice(&((samples.len() * 4) as u32).to_be_bytes());
        for sample in samples {
            frame.extend_from_slice(&sample.to_le_bytes());
        }
        write_before(
            stream,
            &frame,
            reservation.min(Instant::now() + Duration::from_secs(5)),
        )?;
    }
    drop(samples);
    write_before(
        stream,
        &packet(&json!({"version":1,"type":"end_audio","request_id":"cli"})),
        reservation.min(Instant::now() + Duration::from_secs(5)),
    )?;
    // First terminal byte is not a five-second control exchange. Once started,
    // the frame still has one absolute five-second assembly budget.
    let mut header = [0; 5];
    read_before(
        stream,
        &mut header[..1],
        Instant::now() + Duration::from_secs(125),
    )?;
    let assembly = Instant::now() + Duration::from_secs(5);
    read_before(stream, &mut header[1..], assembly)?;
    let size = u32::from_be_bytes(header[1..].try_into().unwrap()) as usize;
    if header[0] != 1 || size > CONTROL {
        return Err("incompatible_protocol");
    }
    let mut bytes = vec![0; size];
    read_before(stream, &mut bytes, assembly)?;
    let result = decode_response(&bytes, "end_audio")?;
    let text = result["text"].as_str().ok_or("incompatible_protocol")?;
    if DELIVERY
        .compare_exchange(0, 2, Ordering::Relaxed, Ordering::Relaxed)
        .is_err()
    {
        return Err("interrupted");
    }
    if !text.trim().is_empty() {
        let mut stdout = std::io::stdout().lock();
        stdout
            .write_all(text.as_bytes())
            .and_then(|_| stdout.write_all(b"\n"))
            .map_err(|_| "output_failed")?;
    }
    Ok(())
}

pub fn cli() -> SafeResult<()> {
    let mut args: Vec<_> = std::env::args_os()
        .skip(1)
        .map(|s| s.into_string().map_err(|_| "invalid_arguments"))
        .collect::<SafeResult<_>>()?;
    if args.first().is_some_and(|arg| arg == "model") {
        return match args.as_slice() {
            [_, command, id] if command == "install" => crate::model::install(id, None),
            [_, command, id, option, source] if command == "install" && option == "--from" => {
                crate::model::install(id, Some(std::path::Path::new(source)))
            }
            _ => Err("invalid_arguments"),
        };
    }
    // Explicit internal controlled-slice harness, never inferred from environment.
    let fake_tests = args.first().is_some_and(|c| c == "__serve")
        && args.last().is_some_and(|c| c == "--fake-test-controls");
    if fake_tests {
        args.pop();
    }
    let command = args.first().map(String::as_str).ok_or(
        "usage: hagig status|stop; hagig start|fake-request --fake-worker [--network-isolation required|disabled]",
    )?;
    let mode = match args.as_slice() {
        [c] if matches!(c.as_str(), "status" | "stop" | "start" | "__serve") => {
            NetworkIsolation::Required
        }
        [c, path] if c == "transcribe" && path != "--fake-worker" => NetworkIsolation::Required,
        [_, f] if f == "--fake-worker" => NetworkIsolation::Required,
        [_, f, option, value] if f == "--fake-worker" && option == "--network-isolation" => {
            match value.as_str() {
                "required" => NetworkIsolation::Required,
                "disabled" => NetworkIsolation::Disabled,
                _ => return Err("invalid_isolation_mode"),
            }
        }
        _ => return Err("invalid_arguments"),
    };
    let fake = args.get(1).is_some_and(|arg| arg == "--fake-worker");
    if command == "__serve" {
        if fake_tests && !fake {
            return Err("invalid_arguments");
        }
        let settings = if fake {
            None
        } else {
            Some(InferenceSettings::load()?)
        };
        return serve(
            settings
                .as_ref()
                .map_or(mode, |s| s.config.network_isolation()),
            fake_tests,
            settings,
        );
    }
    if !["start", "transcribe", "fake-request", "status", "stop"].contains(&command) {
        return Err("invalid_command");
    }
    if command == "transcribe" {
        if fake {
            return Err("invalid_arguments");
        }
        install_interrupt_handler()?;
    }
    let starts = matches!(command, "start" | "transcribe" | "fake-request");
    let path = runtime(starts)?;
    let mut stream = connect(&path)?;
    if stream.is_none() && starts {
        let server_args = if fake {
            vec![
                "__serve".to_owned(),
                "--fake-worker".into(),
                "--network-isolation".into(),
                mode.to_string(),
            ]
        } else {
            InferenceSettings::load()?;
            vec!["__serve".to_owned()]
        };
        let mut child = Command::new(std::env::current_exe().map_err(|_| "startup_failed")?)
            .args(server_args)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            // A terminal Ctrl-C cancels the client, not the shared server group.
            .process_group(0)
            .spawn()
            .map_err(|_| "startup_failed")?;
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline {
            match connect(&path) {
                Ok(Some(s)) => {
                    stream = Some(s);
                    break;
                }
                Ok(None) => (),
                Err(error) => {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(error);
                }
            }
            std::thread::sleep(TICK);
        }
        // Reap losing/failed startup children. A winner remains the on-demand server.
        if stream.is_none() {
            let _ = child.kill();
            let _ = child.wait();
            return Err("startup_failed");
        }
        std::thread::spawn(move || {
            let _ = child.wait();
        });
    }
    let Some(mut stream) = stream else {
        println!("stopped");
        return Ok(());
    };
    let hello = exchange(&mut stream, "hello")?;
    if starts && hello["worker"] != if fake { "controlled_fake" } else { "inference" } {
        return Err("incompatible_protocol");
    }
    if command == "transcribe" {
        return transcribe(&mut stream, &hello, std::path::Path::new(&args[1]));
    }
    if command == "fake-request" {
        exchange(&mut stream, "begin")?;
        let result = exchange(&mut stream, "end_audio")?;
        if result["request_id"] != "cli" || result["text"] != "" {
            return Err("incompatible_protocol");
        }
        println!();
        return Ok(());
    }
    let response = exchange(
        &mut stream,
        if command == "stop" { "stop" } else { "status" },
    )?;
    if command == "stop" {
        validate(&path.join("server.lock"), 0o600, "file")?;
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .open(path.join("server.lock"))
            .map_err(|_| "cleanup_failed")?;
        let deadline = Instant::now() + Duration::from_secs(6);
        loop {
            if lock.try_lock().is_ok() {
                if fs::symlink_metadata(path.join("server.sock")).is_ok() {
                    return Err("cleanup_failed");
                }
                break;
            }
            if Instant::now() >= deadline {
                return Err("cleanup_failed");
            }
            std::thread::sleep(TICK);
        }
    }
    println!("{response}");
    Ok(())
}
