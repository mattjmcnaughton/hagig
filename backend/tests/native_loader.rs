//! Opt-in relocated native-loader check, NOT model inference/adoption evidence.
#![cfg(unix)]

use hagig::launcher::{PlatformLauncher, WorkerExecutable};
use hagig::supervisor::Supervisor;
use hagig::worker_protocol::{self, Reply, Request};
use std::io::{Read, Write};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::time::Duration;

#[test]
#[ignore = "requires an explicitly prepared relocated native candidate bundle"]
fn relocated_native_helper_replies_under_required_isolation() {
    let bootstrap = PathBuf::from(
        std::env::var_os("HAGIG_NATIVE_BOOTSTRAP")
            .expect("set HAGIG_NATIVE_BOOTSTRAP to the prepared trusted bootstrap"),
    );
    let missing = bootstrap.with_file_name("not-installed");
    assert!(!missing.exists(), "fixture model must be absent");
    let launcher = PlatformLauncher::new(WorkerExecutable::new(bootstrap).unwrap());
    let mut supervisor = Supervisor::new(launcher);
    let mut pipes = supervisor.start().expect("required bootstrap launch");
    let pid = supervisor.child_id().unwrap();
    let request = Request {
        version: 1,
        generation: 739,
        request_id: "native-loader-check".into(),
        model: missing,
        hotwords: String::new(),
        audio_bytes: 4,
    };
    pipes
        .input
        .write_all(&worker_protocol::encode(&request).unwrap())
        .expect("native reply required after bootstrap ACK");
    pipes
        .input
        .write_all(&0.0_f32.to_le_bytes())
        .expect("native reply required after bootstrap ACK");
    drop(pipes.input);
    let (sender, receiver) = mpsc::channel();
    let reader = std::thread::spawn(move || {
        let mut bytes = Vec::new();
        let result = pipes
            .output
            .take((worker_protocol::CONTROL + 6) as u64)
            .read_to_end(&mut bytes);
        let _ = sender.send(result.map(|_| bytes));
    });
    let bytes = receiver
        .recv_timeout(Duration::from_secs(10))
        .expect("native reply deadline")
        .expect("native reply read");
    assert!(
        bytes.len() >= 5,
        "native reply required after bootstrap ACK"
    );
    assert_eq!(bytes[0], 1);
    let size = u32::from_be_bytes(bytes[1..5].try_into().unwrap()) as usize;
    assert_eq!(bytes.len(), size + 5, "one complete native reply then EOF");
    let reply: Reply = serde_json::from_slice(&bytes[5..]).unwrap();
    assert_eq!(reply.version, request.version);
    assert_eq!(reply.generation, request.generation);
    assert_eq!(reply.request_id, request.request_id);
    assert_eq!(reply.code.as_deref(), Some("model_missing"));
    assert!(reply.text.is_none());
    reader.join().unwrap();
    supervisor.stop().unwrap();
    assert!(supervisor.child_id().is_none());
    assert!(
        !Command::new("/bin/kill")
            .args(["-0", &pid.to_string()])
            .stderr(Stdio::null())
            .status()
            .unwrap()
            .success(),
        "native child reaped"
    );
    println!("NATIVE LOADER PASS: Required bootstrap/native reply/reap; no model inference claim");
}
