use std::process::Command;

#[test]
fn absent_status_and_stop_do_not_start_server() {
    let root = std::env::temp_dir().join(format!("hagig-contract-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir(&root).unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
    for command in ["status", "stop"] {
        let output = Command::new(env!("CARGO_BIN_EXE_hagig"))
            .env("XDG_RUNTIME_DIR", &root)
            .arg(command)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{command} must succeed when absent"
        );
        assert_eq!(String::from_utf8(output.stdout).unwrap().trim(), "stopped");
        assert!(!root.join("hagig/server.sock").exists());
    }
    std::fs::remove_dir_all(root).unwrap();
}

use serde_json::{Value, json};
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::time::{Duration, Instant};

struct Service {
    root: std::path::PathBuf,
    child: std::process::Child,
}
impl Service {
    fn new(mode: &str) -> Self {
        Self::configured(mode, false)
    }
    fn controlled() -> Self {
        Self::configured("disabled", true)
    }
    fn configured(mode: &str, fake_tests: bool) -> Self {
        static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let root = std::env::temp_dir().join(format!(
            "hg-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        ));
        std::fs::create_dir(&root).unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
        let mut command = Command::new(env!("CARGO_BIN_EXE_hagig"));
        command.env("XDG_RUNTIME_DIR", &root).args([
            "__serve",
            "--fake-worker",
            "--network-isolation",
            mode,
        ]);
        if fake_tests {
            command.arg("--fake-test-controls");
        }
        let child = command.spawn().unwrap();
        let mut service = Self { root, child };
        let deadline = Instant::now() + Duration::from_secs(5);
        while !service.root.join("hagig/server.sock").exists() {
            assert!(
                service.child.try_wait().unwrap().is_none(),
                "server exited before ready"
            );
            assert!(Instant::now() < deadline, "server startup timeout");
            std::thread::sleep(Duration::from_millis(10));
        }
        service
    }
    fn client(&self) -> UnixStream {
        let mut c = UnixStream::connect(self.root.join("hagig/server.sock")).unwrap();
        c.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
        c.set_write_timeout(Some(Duration::from_secs(3))).unwrap();
        send(&mut c, json!({"version":1,"type":"hello"}));
        assert_eq!(receive(&mut c)["type"], "hello_ok");
        c
    }
    fn cli(&self, args: &[&str]) -> std::process::Output {
        let output = Command::new(env!("CARGO_BIN_EXE_hagig"))
            .env("XDG_RUNTIME_DIR", &self.root)
            .args(args)
            .output()
            .unwrap();
        if !output.status.success() {
            // Controlled fixtures only; CLI stderr contains stable content-free codes.
            eprintln!(
                "controlled CLI {args:?}: status={} stderr={}",
                output.status,
                String::from_utf8_lossy(&output.stderr)
            );
        }
        output
    }
    fn stopped(&mut self) {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            if let Some(status) = self.child.try_wait().unwrap() {
                assert!(status.success());
                break;
            }
            assert!(Instant::now() < deadline, "server failed to stop");
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(!self.root.join("hagig/server.sock").exists());
        assert!(self.cli(&["status"]).status.success());
    }
}
impl Drop for Service {
    fn drop(&mut self) {
        let _ = self.cli(&["stop"]);
        std::thread::sleep(Duration::from_millis(100));
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = std::fs::remove_dir_all(&self.root);
    }
}
fn send(c: &mut UnixStream, value: Value) {
    let bytes = serde_json::to_vec(&value).unwrap();
    let mut frame = vec![1];
    frame.extend_from_slice(&(bytes.len() as u32).to_be_bytes());
    frame.extend(bytes);
    c.write_all(&frame).unwrap();
}
fn receive(c: &mut UnixStream) -> Value {
    let mut header = [0; 5];
    assert!(
        c.read_exact(&mut header).is_ok(),
        "expected framed response, not disconnect/timeout"
    );
    assert_eq!(header[0], 1);
    let len = u32::from_be_bytes(header[1..].try_into().unwrap()) as usize;
    assert!(len <= 65536);
    let mut bytes = vec![0; len];
    c.read_exact(&mut bytes).unwrap();
    serde_json::from_slice(&bytes).unwrap()
}
fn begin(c: &mut UnixStream) -> Value {
    send(c, json!({"version":1,"type":"begin","request_id":"same"}));
    receive(c)
}
fn wait_idle(c: &mut UnixStream) {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        send(c, json!({"version":1,"type":"status"}));
        if receive(c)["state"] == "idle" {
            break;
        }
        assert!(Instant::now() < deadline, "slot not released");
        std::thread::sleep(Duration::from_millis(10));
    }
}

fn fake_control(c: &mut UnixStream, settings: Value) {
    let mut control = settings;
    control["version"] = json!(1);
    control["type"] = json!("fake_test");
    send(c, control);
    let mut kind = [0];
    assert_eq!(
        c.read(&mut kind).unwrap(),
        1,
        "explicit fake-test server must acknowledge controlled lifecycle operation"
    );
    assert_eq!(kind[0], 1);
    let mut len = [0; 4];
    c.read_exact(&mut len).unwrap();
    let len = u32::from_be_bytes(len) as usize;
    assert!(len <= 65_536);
    let mut bytes = vec![0; len];
    c.read_exact(&mut bytes).unwrap();
    let response: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(response["type"], "fake_test_ok");
}

fn status(c: &mut UnixStream) -> Value {
    send(c, json!({"version":1,"type":"status"}));
    receive(c)
}

fn wait_status(c: &mut UnixStream, field: &str) -> Value {
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        let s = status(c);
        if s[field].as_u64().is_some_and(|n| n > 0) {
            return s;
        }
        assert!(
            Instant::now() < deadline,
            "status {field} never became observable"
        );
        std::thread::sleep(Duration::from_millis(5));
    }
}

fn assert_dead(pid: u64) {
    assert!(
        !Command::new("/bin/kill")
            .args(["-0", &pid.to_string()])
            .stderr(std::process::Stdio::null())
            .status()
            .unwrap()
            .success(),
        "owned child {pid} must be reaped"
    );
}

#[test]
fn fake_test_controls_require_explicit_foreground_opt_in() {
    let service = Service::new("disabled");
    assert!(status(&mut service.client())["pending_results"].is_null());
    for value in [
        json!({"version":1,"type":"fake_test","fake_pause_delivery":true}),
        json!({"version":1,"type":"fake_test","fake_advance_seconds":331}),
        json!({"version":1,"type":"status","fake_pause_delivery":true}),
        json!({"version":1,"type":"begin","request_id":"same","fake_action":"complete"}),
        json!({"version":1,"type":"stop","request_id":"same"}),
        json!({"version":1,"type":"cancel"}),
    ] {
        let mut c = service.client();
        send(&mut c, value);
        assert_eq!(
            c.read(&mut [0]).unwrap(),
            0,
            "illegal field combinations must close only the peer"
        );
    }
    let rejected = service.cli(&["start", "--fake-worker", "--fake-test-controls"]);
    assert_eq!(rejected.status.code(), Some(1));
    assert_eq!(rejected.stderr, b"invalid_arguments\n");
    assert!(
        service
            .cli(&[
                "fake-request",
                "--fake-worker",
                "--network-isolation",
                "disabled"
            ])
            .status
            .success()
    );
}

#[test]
fn pending_success_cancel_reused_id_and_result_first_ordering() {
    let service = Service::controlled();
    let mut observer = service.client();
    let mut owner = service.client();
    fake_control(&mut observer, json!({"fake_pause_delivery":true}));
    assert_eq!(begin(&mut owner)["type"], "accepted");
    send(
        &mut owner,
        json!({"version":1,"type":"end_audio","request_id":"same"}),
    );
    // This marker means a real worker's success is serialized but has not begun
    // delivery. It is not merely a live process killed before it can succeed.
    wait_status(&mut observer, "pending_results");
    send(
        &mut owner,
        json!({"version":1,"type":"cancel","request_id":"same"}),
    );
    assert_eq!(
        receive(&mut owner)["type"],
        "cancelled",
        "cancel must discard pending success"
    );
    assert_eq!(status(&mut observer)["pending_results"], 0);
    assert_eq!(begin(&mut owner)["type"], "accepted");
    send(
        &mut owner,
        json!({"version":1,"type":"end_audio","request_id":"same","fake_action":"crash"}),
    );
    assert_eq!(
        receive(&mut owner)["code"],
        "worker_failed",
        "reused ID must not receive the old success"
    );
    fake_control(&mut observer, json!({"fake_pause_delivery":false}));
    assert_eq!(begin(&mut owner)["type"], "accepted");
    send(
        &mut owner,
        json!({"version":1,"type":"end_audio","request_id":"same"}),
    );
    assert_eq!(
        receive(&mut owner)["type"],
        "result",
        "result-first control must still deliver"
    );
    send(
        &mut owner,
        json!({"version":1,"type":"cancel","request_id":"same"}),
    );
    assert_eq!(receive(&mut owner)["type"], "cancelled");
    assert!(
        service
            .cli(&[
                "fake-request",
                "--fake-worker",
                "--network-isolation",
                "disabled"
            ])
            .status
            .success()
    );
}

#[test]
fn reservation_and_computation_deadlines_reap_and_recover() {
    let service = Service::controlled();
    let mut observer = service.client();
    // Exercise expiry becoming due before the owner's turn in a service tick.
    let mut owner = service.client();
    assert_eq!(begin(&mut owner)["type"], "accepted");
    fake_control(&mut observer, json!({"fake_advance_seconds":329}));
    assert_eq!(
        status(&mut observer)["state"],
        "busy",
        "reservation must not expire early"
    );
    fake_control(&mut observer, json!({"fake_advance_seconds":2}));
    let expiry = receive(&mut owner);
    assert_eq!(expiry["code"], "deadline_exceeded");
    assert_eq!(expiry["request_id"], "same");
    wait_idle(&mut observer);
    assert_eq!(begin(&mut owner)["type"], "accepted");
    send(
        &mut owner,
        json!({"version":1,"type":"end_audio","request_id":"same","fake_action":"stall"}),
    );
    let pid = wait_status(&mut observer, "worker_pid")["worker_pid"]
        .as_u64()
        .unwrap();
    assert_ne!(pid, u64::from(service.child.id()));
    fake_control(&mut observer, json!({"fake_advance_seconds":119}));
    assert_eq!(
        status(&mut owner)["state"],
        "busy",
        "owner must receive status, not an early deadline error"
    );
    fake_control(&mut observer, json!({"fake_advance_seconds":2}));
    let expiry = receive(&mut owner);
    assert_eq!(expiry["code"], "deadline_exceeded");
    assert_eq!(expiry["request_id"], "same");
    wait_idle(&mut observer);
    assert_dead(pid);
    assert_eq!(begin(&mut owner)["type"], "accepted");
    send(
        &mut owner,
        json!({"version":1,"type":"cancel","request_id":"same"}),
    );
    assert_eq!(receive(&mut owner)["type"], "cancelled");
    assert!(
        service
            .cli(&[
                "fake-request",
                "--fake-worker",
                "--network-isolation",
                "disabled"
            ])
            .status
            .success()
    );
}

#[test]
fn computation_expiry_suppresses_already_completed_success() {
    let service = Service::controlled();
    let mut owner = service.client();
    let mut observer = service.client();
    fake_control(&mut observer, json!({"fake_pause_completion":true}));
    assert_eq!(begin(&mut owner)["type"], "accepted");
    send(
        &mut owner,
        json!({"version":1,"type":"end_audio","request_id":"same"}),
    );
    let pending = wait_status(&mut observer, "pending_completions");
    assert_dead(pending["worker_pid"].as_u64().unwrap());
    fake_control(&mut observer, json!({"fake_advance_seconds":121}));
    assert_eq!(receive(&mut owner)["code"], "deadline_exceeded");
    assert_eq!(
        begin(&mut observer)["code"],
        "busy",
        "invalidated generation retains slot until completion observed"
    );
    fake_control(&mut observer, json!({"fake_pause_completion":false}));
    wait_idle(&mut observer);
    assert_eq!(
        begin(&mut owner)["type"],
        "accepted",
        "late success must not precede reused-ID acceptance"
    );
    send(
        &mut owner,
        json!({"version":1,"type":"end_audio","request_id":"same","fake_action":"crash"}),
    );
    assert_eq!(receive(&mut owner)["code"], "worker_failed");
    assert!(
        service
            .cli(&[
                "fake-request",
                "--fake-worker",
                "--network-isolation",
                "disabled"
            ])
            .status
            .success()
    );
}

#[test]
fn admission_ownership_malformed_and_reuse() {
    let mut service = Service::new("disabled");
    let mut owner = service.client();
    assert_eq!(begin(&mut owner)["type"], "accepted");
    let mut other = service.client();
    let start = Instant::now();
    assert_eq!(begin(&mut other)["code"], "busy");
    assert!(start.elapsed() < Duration::from_secs(1));
    send(
        &mut other,
        json!({"version":1,"type":"cancel","request_id":"same"}),
    );
    assert_eq!(receive(&mut other)["type"], "cancelled");
    drop(other);
    let mut observer = service.client();
    for bytes in [
        vec![1, 0, 1, 0, 1],
        vec![2, 0, 4, 0, 1],
        vec![9, 0, 0, 0, 0],
        vec![1, 0, 0, 0, 1, b'{'],
    ] {
        let mut bad = service.client();
        bad.write_all(&bytes).unwrap();
        let mut b = [0];
        assert_eq!(
            bad.read(&mut b).unwrap(),
            0,
            "malformed peer must close, not merely time out"
        );
        assert_eq!(begin(&mut observer)["code"], "busy");
    }
    // Nonowner malformed end must not preempt the owner.
    let mut bad = service.client();
    send(
        &mut bad,
        json!({"version":1,"type":"end_audio","request_id":"same"}),
    );
    let mut b = [0];
    assert_eq!(bad.read(&mut b).unwrap(), 0);
    assert_eq!(begin(&mut observer)["code"], "busy");
    drop(owner);
    wait_idle(&mut observer);
    assert_eq!(begin(&mut observer)["type"], "accepted");
    send(
        &mut observer,
        json!({"version":1,"type":"end_audio","request_id":"same"}),
    );
    let result = receive(&mut observer);
    assert_eq!(result["type"], "result");
    assert_eq!(
        result["text"], "",
        "controlled worker must return explicit empty text, never fabricated transcription"
    );
    assert!(service.cli(&["stop"]).status.success());
    service.stopped();
}

#[test]
fn stop_suppresses_success_already_waiting_for_completion() {
    let mut service = Service::controlled();
    let mut owner = service.client();
    let mut observer = service.client();
    fake_control(&mut observer, json!({"fake_pause_completion":true}));
    assert_eq!(begin(&mut owner)["type"], "accepted");
    send(
        &mut owner,
        json!({"version":1,"type":"end_audio","request_id":"same"}),
    );
    let pending = wait_status(&mut observer, "pending_completions");
    assert_dead(pending["worker_pid"].as_u64().unwrap());
    send(&mut observer, json!({"version":1,"type":"stop"}));
    assert_eq!(receive(&mut observer)["type"], "stopped");
    let mut byte = [0];
    assert_eq!(
        owner.read(&mut byte).unwrap(),
        0,
        "stop must close without starting delivery of pending success"
    );
    service.stopped();
}

#[test]
fn stop_cancels_stalled_worker_and_reaps_before_exit() {
    let mut service = Service::new("disabled");
    let mut owner = service.client();
    assert_eq!(begin(&mut owner)["type"], "accepted");
    send(
        &mut owner,
        json!({"version":1,"type":"end_audio","request_id":"same","fake_action":"stall"}),
    );
    let mut observer = service.client();
    let deadline = Instant::now() + Duration::from_secs(5);
    let pid = loop {
        send(&mut observer, json!({"version":1,"type":"status"}));
        let status = receive(&mut observer);
        if let Some(pid) = status["worker_pid"].as_u64() {
            break pid;
        }
        assert!(
            Instant::now() < deadline,
            "separate worker must be observable"
        );
        std::thread::sleep(Duration::from_millis(10));
    };
    assert!(
        Command::new("/bin/kill")
            .args(["-0", &pid.to_string()])
            .status()
            .unwrap()
            .success()
    );
    assert!(service.cli(&["stop"]).status.success());
    assert!(
        !service.root.join("hagig/server.sock").exists(),
        "CLI stop success must wait for owned socket cleanup"
    );
    service.stopped();
    assert!(
        !Command::new("/bin/kill")
            .args(["-0", &pid.to_string()])
            .stderr(std::process::Stdio::null())
            .status()
            .unwrap()
            .success()
    );
    let mut b = [0];
    assert_eq!(
        owner.read(&mut b).unwrap(),
        0,
        "stop must not deliver stalled work"
    );
}

#[test]
fn startup_contention_permissions_and_lifetime_lock() {
    let mut service = Service::new("disabled");
    use std::os::unix::fs::PermissionsExt;
    assert_eq!(
        std::fs::metadata(service.root.join("hagig"))
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o700
    );
    assert_eq!(
        std::fs::metadata(service.root.join("hagig/server.sock"))
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o600
    );
    let lock = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(service.root.join("hagig/server.lock"))
        .unwrap();
    assert!(matches!(
        lock.try_lock(),
        Err(std::fs::TryLockError::WouldBlock)
    ));
    let mut starters = Vec::new();
    for _ in 0..8 {
        starters.push(
            Command::new(env!("CARGO_BIN_EXE_hagig"))
                .env("XDG_RUNTIME_DIR", &service.root)
                .args(["start", "--fake-worker"])
                .stdout(std::process::Stdio::piped())
                .spawn()
                .unwrap(),
        );
    }
    for starter in starters {
        let output = starter.wait_with_output().unwrap();
        assert!(output.status.success());
        let status: Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(status["server_pid"], service.child.id());
        assert_eq!(
            status["network_isolation"], "disabled",
            "attach must not silently reconfigure winner"
        );
    }
    assert!(service.cli(&["stop"]).status.success());
    service.stopped();
    lock.try_lock().unwrap();
}

#[test]
fn cancellation_late_completion_crash_and_recovery() {
    let mut service = Service::new("disabled");
    let mut owner = service.client();
    let mut observer = service.client();
    assert_eq!(begin(&mut owner)["type"], "accepted");
    send(
        &mut owner,
        json!({"version":1,"type":"end_audio","request_id":"same"}),
    );
    send(
        &mut owner,
        json!({"version":1,"type":"cancel","request_id":"same"}),
    );
    assert_eq!(receive(&mut owner)["type"], "cancelled");
    wait_idle(&mut observer);
    // Reuse ID after reap. A late completion must not appear before this acceptance.
    assert_eq!(begin(&mut owner)["type"], "accepted");
    send(
        &mut owner,
        json!({"version":1,"type":"end_audio","request_id":"same","fake_action":"crash"}),
    );
    assert_eq!(receive(&mut owner)["code"], "worker_failed");
    assert_eq!(begin(&mut owner)["type"], "accepted");
    send(
        &mut owner,
        json!({"version":1,"type":"end_audio","request_id":"same"}),
    );
    assert_eq!(receive(&mut owner)["type"], "result");
    // Completion wins first: a later idempotent cancellation cannot undo delivery.
    send(
        &mut owner,
        json!({"version":1,"type":"cancel","request_id":"same"}),
    );
    assert_eq!(receive(&mut owner)["type"], "cancelled");
    assert!(service.cli(&["stop"]).status.success());
    service.stopped();
}

#[test]
fn invalid_version_owner_audio_and_nonowner_version_isolation() {
    let mut service = Service::new("disabled");
    let mut owner = service.client();
    assert_eq!(begin(&mut owner)["type"], "accepted");
    let mut bad = UnixStream::connect(service.root.join("hagig/server.sock")).unwrap();
    bad.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
    send(&mut bad, json!({"version":99,"type":"stop"}));
    assert_eq!(receive(&mut bad)["code"], "incompatible_protocol");
    let mut observer = service.client();
    assert_eq!(begin(&mut observer)["code"], "busy");
    // Version mismatch from the owner is malformed and must invalidate its slot.
    send(&mut owner, json!({"version":99,"type":"status"}));
    assert_eq!(receive(&mut owner)["code"], "incompatible_protocol");
    wait_idle(&mut observer);
    assert_eq!(begin(&mut observer)["type"], "accepted");
    // Unaligned PCM closes only its owner and frees the slot.
    observer.write_all(&[2, 0, 0, 0, 1, 0]).unwrap();
    let mut b = [0];
    assert_eq!(observer.read(&mut b).unwrap(), 0);
    let mut next = service.client();
    wait_idle(&mut next);
    assert!(service.cli(&["stop"]).status.success());
    service.stopped();
}

#[test]
fn unsafe_objects_fail_closed_and_safe_stale_socket_recovers() {
    use std::os::unix::fs::{PermissionsExt, symlink};
    let mut service = Service::new("disabled");
    assert!(service.cli(&["stop"]).status.success());
    service.stopped();
    let socket = service.root.join("hagig/server.sock");
    let lock = service.root.join("hagig/server.lock");
    let canary = service.root.join("private-canary");
    std::fs::write(&canary, "do-not-touch").unwrap();
    for target in [&socket, &lock] {
        let _ = std::fs::remove_file(target);
        symlink(&canary, target).unwrap();
        let out = service.cli(&["__serve", "--fake-worker"]);
        assert!(!out.status.success());
        assert!(!String::from_utf8_lossy(&out.stderr).contains("private-canary"));
        assert_eq!(std::fs::read_to_string(&canary).unwrap(), "do-not-touch");
        assert!(
            std::fs::symlink_metadata(target)
                .unwrap()
                .file_type()
                .is_symlink()
        );
        std::fs::remove_file(target).unwrap();
    }
    // An ordinary file is never treated as a stale socket or deleted.
    std::fs::write(&socket, "retain").unwrap();
    std::fs::set_permissions(&socket, std::fs::Permissions::from_mode(0o600)).unwrap();
    assert!(!service.cli(&["start", "--fake-worker"]).status.success());
    assert_eq!(std::fs::read_to_string(&socket).unwrap(), "retain");
    std::fs::remove_file(&socket).unwrap();
    let stale = std::os::unix::net::UnixListener::bind(&socket).unwrap();
    std::fs::set_permissions(&socket, std::fs::Permissions::from_mode(0o600)).unwrap();
    drop(stale);
    assert!(
        service
            .cli(&["start", "--fake-worker", "--network-isolation", "disabled"])
            .status
            .success()
    );
    assert!(service.cli(&["stop"]).status.success());
    assert!(!socket.exists());
    // Unsafe runtime permission is refused, not repaired.
    let runtime = service.root.join("hagig");
    std::fs::set_permissions(&runtime, std::fs::Permissions::from_mode(0o755)).unwrap();
    assert!(!service.cli(&["status"]).status.success());
    assert_eq!(
        std::fs::metadata(&runtime).unwrap().permissions().mode() & 0o777,
        0o755
    );
}

#[test]
fn bounded_pcm_upload_fragmentation_and_owner_malformed_cleanup() {
    let mut service = Service::new("disabled");
    let mut owner = service.client();
    assert_eq!(begin(&mut owner)["type"], "accepted");
    let mut audio = vec![2];
    audio.extend_from_slice(&262_144u32.to_be_bytes());
    audio.resize(262_149, 0);
    // Exactly five minutes, then one aligned sample over the aggregate cap.
    for _ in 0..73 {
        owner.write_all(&audio).unwrap();
    }
    let remainder = 19_200_000 - 73 * 262_144;
    let mut last = vec![2];
    last.extend_from_slice(&(remainder as u32).to_be_bytes());
    last.resize(remainder + 5, 0);
    owner.write_all(&last).unwrap();
    // The exact aggregate boundary remains valid, not just the oversized case.
    send(&mut owner, json!({"version":1,"type":"status"}));
    assert_eq!(receive(&mut owner)["state"], "busy");
    let mut maximum_control = br#"{"version":1,"type":"status"}"#.to_vec();
    maximum_control.resize(65_536, b' ');
    let mut maximum_frame = vec![1];
    maximum_frame.extend_from_slice(&65_536u32.to_be_bytes());
    maximum_frame.extend(maximum_control);
    owner.write_all(&maximum_frame).unwrap();
    assert_eq!(receive(&mut owner)["state"], "busy");
    owner.write_all(&[2, 0, 0, 0, 4, 0, 0, 0, 0]).unwrap();
    let mut b = [0];
    assert_eq!(owner.read(&mut b).unwrap(), 0);
    let mut next = service.client();
    wait_idle(&mut next);
    // A fragmented valid control is decoded without consuming the following one.
    let bytes = br#"{"version":1,"type":"begin","request_id":"fragment"}"#;
    let mut frame = vec![1];
    frame.extend_from_slice(&(bytes.len() as u32).to_be_bytes());
    frame.extend_from_slice(bytes);
    for byte in frame {
        next.write_all(&[byte]).unwrap();
    }
    assert_eq!(receive(&mut next)["type"], "accepted");
    send(
        &mut next,
        json!({"version":1,"type":"status","unknown":"sensitive-canary"}),
    );
    assert_eq!(next.read(&mut b).unwrap(), 0);
    assert!(service.cli(&["stop"]).status.success());
    service.stopped();
}

#[test]
fn cold_cli_startup_converges_and_required_is_default() {
    let mut service = Service::new("disabled");
    assert!(service.cli(&["stop"]).status.success());
    service.stopped();
    let mut starters = Vec::new();
    for _ in 0..8 {
        starters.push(
            Command::new(env!("CARGO_BIN_EXE_hagig"))
                .env("XDG_RUNTIME_DIR", &service.root)
                .args(["start", "--fake-worker"])
                .stdout(std::process::Stdio::piped())
                .spawn()
                .unwrap(),
        );
    }
    let mut pids = Vec::new();
    for starter in starters {
        let output = starter.wait_with_output().unwrap();
        assert!(output.status.success());
        let status: Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(status["network_isolation"], "required");
        pids.push(status["server_pid"].as_u64().unwrap());
    }
    assert!(
        pids.iter().all(|pid| *pid == pids[0]),
        "one server wins simultaneous cold startup"
    );
    let mut c = service.client();
    assert_eq!(begin(&mut c)["type"], "accepted");
    send(
        &mut c,
        json!({"version":1,"type":"end_audio","request_id":"same"}),
    );
    let result = receive(&mut c);
    // A restricted host may refuse Required; it must not report disabled or retry.
    assert!(result["type"] == "result" || result["code"] == "worker_failed");
    let status = service.cli(&["status"]);
    assert_eq!(
        serde_json::from_slice::<Value>(&status.stdout).unwrap()["network_isolation"],
        "required"
    );
    assert!(service.cli(&["stop"]).status.success());
    assert!(!service.root.join("hagig/server.sock").exists());
}

#[test]
fn connection_limit_is_bounded_and_does_not_preempt_owner() {
    let mut service = Service::new("disabled");
    let mut owner = service.client();
    assert_eq!(begin(&mut owner)["type"], "accepted");
    let others: Vec<_> = (0..31).map(|_| service.client()).collect();
    let mut excess = UnixStream::connect(service.root.join("hagig/server.sock")).unwrap();
    excess
        .set_read_timeout(Some(Duration::from_secs(2)))
        .unwrap();
    let mut b = [0];
    assert_eq!(excess.read(&mut b).unwrap(), 0);
    drop(others);
    std::thread::sleep(Duration::from_millis(30));
    let mut observer = service.client();
    assert_eq!(begin(&mut observer)["code"], "busy");
    drop(owner);
    wait_idle(&mut observer);
    assert!(service.cli(&["stop"]).status.success());
    service.stopped();
}

#[test]
fn controlled_cli_request_returns_only_empty_text_and_busy_exit_three() {
    let mut service = Service::new("disabled");
    let mut owner = service.client();
    assert_eq!(begin(&mut owner)["type"], "accepted");
    let busy = service.cli(&["fake-request", "--fake-worker"]);
    assert_eq!(busy.status.code(), Some(3));
    assert!(busy.stdout.is_empty());
    assert_eq!(busy.stderr, b"busy\n");
    drop(owner);
    let mut observer = service.client();
    wait_idle(&mut observer);
    let result = service.cli(&["fake-request", "--fake-worker"]);
    assert!(result.status.success());
    assert_eq!(result.stdout, b"\n");
    assert!(result.stderr.is_empty());
    assert!(service.cli(&["stop"]).status.success());
    service.stopped();
}

#[test]
fn partial_frame_drip_has_absolute_deadline_without_disturbing_owner() {
    let mut service = Service::new("disabled");
    let mut owner = service.client();
    assert_eq!(begin(&mut owner)["type"], "accepted");
    let mut slow = service.client();
    slow.set_read_timeout(Some(Duration::from_millis(300)))
        .unwrap();
    slow.write_all(&[1, 0, 0, 1, 0]).unwrap();
    for _ in 0..6 {
        std::thread::sleep(Duration::from_secs(1));
        let _ = slow.write_all(b" ");
    }
    let mut b = [0];
    let outcome = slow.read(&mut b);
    assert!(
        matches!(outcome, Ok(0)),
        "a byte drip must not reset frame assembly deadline: {outcome:?}"
    );
    let mut observer = service.client();
    assert_eq!(begin(&mut observer)["code"], "busy");
    drop(owner);
    wait_idle(&mut observer);
    assert!(service.cli(&["stop"]).status.success());
    service.stopped();
}

#[test]
fn owner_disconnect_reaps_actual_stalled_process_and_recovers() {
    let mut service = Service::new("disabled");
    let mut owner = service.client();
    assert_eq!(begin(&mut owner)["type"], "accepted");
    send(
        &mut owner,
        json!({"version":1,"type":"end_audio","request_id":"same","fake_action":"stall"}),
    );
    let mut observer = service.client();
    let deadline = Instant::now() + Duration::from_secs(5);
    let pid = loop {
        send(&mut observer, json!({"version":1,"type":"status"}));
        if let Some(pid) = receive(&mut observer)["worker_pid"].as_u64() {
            break pid;
        }
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(10));
    };
    assert!(
        Command::new("/bin/kill")
            .args(["-0", &pid.to_string()])
            .status()
            .unwrap()
            .success()
    );
    // Closing a fresh nonowner cannot kill the live stalled process.
    drop(service.client());
    assert_eq!(begin(&mut observer)["code"], "busy");
    assert!(
        Command::new("/bin/kill")
            .args(["-0", &pid.to_string()])
            .status()
            .unwrap()
            .success()
    );
    drop(owner);
    wait_idle(&mut observer);
    assert!(
        !Command::new("/bin/kill")
            .args(["-0", &pid.to_string()])
            .stderr(std::process::Stdio::null())
            .status()
            .unwrap()
            .success()
    );
    assert_eq!(begin(&mut observer)["type"], "accepted");
    send(
        &mut observer,
        json!({"version":1,"type":"end_audio","request_id":"same"}),
    );
    assert_eq!(receive(&mut observer)["type"], "result");
    for _ in 0..8 {
        send(
            &mut observer,
            json!({"version":1,"type":"cancel","request_id":"same"}),
        );
        assert_eq!(receive(&mut observer)["type"], "cancelled");
    }
    assert!(service.cli(&["stop"]).status.success());
    service.stopped();
}

#[test]
fn cli_accepts_complete_terminal_reply_after_peer_close() {
    let mut service = Service::new("disabled");
    assert!(service.cli(&["stop"]).status.success());
    service.stopped();
    let socket = service.root.join("hagig/server.sock");
    let listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&socket, std::fs::Permissions::from_mode(0o600)).unwrap();
    let peer = std::thread::spawn(move || {
        for _ in 0..8 {
            let (mut c, _) = listener.accept().unwrap();
            c.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
            assert_eq!(receive(&mut c)["type"], "hello");
            send(&mut c, json!({"version":1,"type":"hello_ok"}));
            assert_eq!(receive(&mut c)["type"], "status");
            send(&mut c, json!({"version":1,"type":"status","state":"idle"}));
            // Final bytes remain readable even after the peer closes. Do not
            // depend on setting a socket option before consuming those bytes.
            c.shutdown(std::net::Shutdown::Both).unwrap();
        }
    });
    for _ in 0..8 {
        let output = service.cli(&["status"]);
        assert!(output.status.success());
        let reply: Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(reply["type"], "status");
        assert_eq!(reply["state"], "idle");
    }
    peer.join().unwrap();
    std::fs::remove_file(socket).unwrap();
}

#[test]
fn cli_response_frame_deadline_does_not_reset_on_each_byte() {
    let mut service = Service::new("disabled");
    assert!(service.cli(&["stop"]).status.success());
    service.stopped();
    let socket = service.root.join("hagig/server.sock");
    let listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&socket, std::fs::Permissions::from_mode(0o600)).unwrap();
    let peer = std::thread::spawn(move || {
        let (mut c, _) = listener.accept().unwrap();
        let mut request = [0; 5];
        c.read_exact(&mut request).unwrap();
        for byte in [1, 0, 0, 0, 60, b'{', b' ', b' '] {
            if c.write_all(&[byte]).is_err() {
                break;
            }
            std::thread::sleep(Duration::from_secs(1));
        }
    });
    let start = Instant::now();
    let output = service.cli(&["status"]);
    let elapsed = start.elapsed();
    peer.join().unwrap();
    std::fs::remove_file(socket).unwrap();
    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
    assert!(
        elapsed < Duration::from_secs(6),
        "a fragmented response must use a total frame deadline, elapsed={elapsed:?}"
    );
}
