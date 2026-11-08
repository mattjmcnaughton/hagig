//! Real protocol/state checks without adopting or substituting an inference peer.
use serde_json::{Value, json};
use std::fs;
use std::io::{Read, Write};
use std::os::unix::fs::DirBuilderExt;
use std::os::unix::net::UnixStream;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

struct Service {
    root: std::path::PathBuf,
    child: Child,
}
impl Service {
    fn new(name: &str) -> Self {
        let root = std::env::temp_dir().join(format!("hg-{name}-{}", std::process::id()));
        fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
        fs::create_dir_all(root.join("config/hagig")).unwrap();
        fs::write(
            root.join("config/hagig/config.toml"),
            "[editor]\nmode='vim'",
        )
        .unwrap();
        let child = Command::new(env!("CARGO_BIN_EXE_hagig"))
            .env("XDG_RUNTIME_DIR", &root)
            .env("XDG_CONFIG_HOME", root.join("config"))
            .env("XDG_DATA_HOME", root.join("data"))
            .arg("__serve")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let mut service = Self { root, child };
        let deadline = Instant::now() + Duration::from_secs(5);
        while !service.root.join("hagig/server.sock").exists() {
            assert!(
                service.child.try_wait().unwrap().is_none(),
                "real server exited"
            );
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(5));
        }
        service
    }
    fn client(&self) -> UnixStream {
        let stream = UnixStream::connect(self.root.join("hagig/server.sock")).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        stream
            .set_write_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        stream
    }
}
impl Drop for Service {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = fs::remove_dir_all(&self.root);
    }
}
fn send(stream: &mut UnixStream, value: Value) {
    let bytes = serde_json::to_vec(&value).unwrap();
    stream
        .write_all(&[&[1][..], &(bytes.len() as u32).to_be_bytes(), &bytes].concat())
        .unwrap();
}
fn receive(stream: &mut UnixStream) -> Value {
    let mut header = [0; 5];
    stream.read_exact(&mut header).unwrap();
    let size = u32::from_be_bytes(header[1..].try_into().unwrap()) as usize;
    assert_eq!(header[0], 1);
    assert!(size <= 65_536);
    let mut bytes = vec![0; size];
    stream.read_exact(&mut bytes).unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

#[test]
fn real_settings_admission_empty_audio_and_missing_model_have_no_fake_fallback() {
    let service = Service::new("real");
    let mut c = service.client();
    send(&mut c, json!({"version":1,"type":"hello"}));
    let hello = receive(&mut c);
    assert_eq!(hello["version"], 1);
    assert_eq!(hello["type"], "hello_ok");
    assert_eq!(hello["worker"], "inference");
    assert_eq!(hello["network_isolation"], "required");
    assert_eq!(hello["settings"]["editor_mode"], "vim");
    assert_eq!(
        hello["settings"]["model_id"],
        "parakeet-tdt-0.6b-v2-int8-v1"
    );
    assert_eq!(
        hello["audio"],
        json!({"encoding":"f32le","sample_rate_hz":16000,"channels":1})
    );
    assert_eq!(hello["limits"]["audio_total_bytes"], 19_200_000);
    assert_eq!(hello["deadlines"]["computation_seconds"], 120);
    for field in [
        "fake_action",
        "fake_pause_delivery",
        "fake_pause_completion",
        "fake_advance_seconds",
    ] {
        let mut malformed = service.client();
        let mut control = json!({"version":1,"type":"hello"});
        control[field] = Value::Null;
        send(&mut malformed, control);
        assert_eq!(
            malformed.read(&mut [0; 1]).unwrap(),
            0,
            "real service must reject the fake field {field}, even when null"
        );
    }
    fs::write(
        service.root.join("config/hagig/config.toml"),
        "[editor]\nmode='standard'",
    )
    .unwrap();
    let mut other = service.client();
    send(&mut other, json!({"version":1,"type":"hello"}));
    assert_eq!(receive(&mut other), hello, "live configuration is frozen");
    send(
        &mut c,
        json!({"version":1,"type":"begin","request_id":"r1"}),
    );
    let accepted = receive(&mut c);
    assert_eq!(accepted["version"], 1);
    assert_eq!(accepted["type"], "accepted");
    assert_eq!(accepted["request_id"], "r1");
    assert_eq!(accepted["config_generation"], hello["config_generation"]);
    assert_eq!(accepted["model_id"], hello["settings"]["model_id"]);
    send(
        &mut other,
        json!({"version":1,"type":"begin","request_id":"r2"}),
    );
    assert_eq!(receive(&mut other)["code"], "busy");
    send(
        &mut c,
        json!({"version":1,"type":"end_audio","request_id":"r1"}),
    );
    assert_eq!(
        receive(&mut c),
        json!({"version":1,"type":"error","request_id":"r1","code":"invalid_audio"})
    );
    send(
        &mut c,
        json!({"version":1,"type":"begin","request_id":"r3"}),
    );
    assert_eq!(receive(&mut c)["type"], "accepted");
    c.write_all(&[&[2][..], &4_u32.to_be_bytes(), &0.125_f32.to_le_bytes()].concat())
        .unwrap();
    send(
        &mut c,
        json!({"version":1,"type":"end_audio","request_id":"r3"}),
    );
    assert_eq!(
        receive(&mut c),
        json!({"version":1,"type":"error","request_id":"r3","code":"model_missing"})
    );
    assert!(
        !service.root.join("data").exists(),
        "inference must not install or stage models"
    );
    let path = service.root.join("PRIVATE_AUDIO_CANARY.wav");
    let wav = [
        b"RIFF".as_slice(),
        &38_u32.to_le_bytes(),
        b"WAVEfmt ",
        &16_u32.to_le_bytes(),
        &1_u16.to_le_bytes(),
        &1_u16.to_le_bytes(),
        &16_000_u32.to_le_bytes(),
        &32_000_u32.to_le_bytes(),
        &2_u16.to_le_bytes(),
        &16_u16.to_le_bytes(),
        b"data",
        &2_u32.to_le_bytes(),
        &(-4096_i16).to_le_bytes(),
    ]
    .concat();
    fs::write(&path, &wav).unwrap();
    let invoke = || {
        Command::new(env!("CARGO_BIN_EXE_hagig"))
            .env("XDG_RUNTIME_DIR", &service.root)
            .env("XDG_CONFIG_HOME", service.root.join("config"))
            .env("XDG_DATA_HOME", service.root.join("data"))
            .arg("transcribe")
            .arg(&path)
            .output()
            .unwrap()
    };
    let missing = invoke();
    assert_eq!(missing.status.code(), Some(1));
    assert!(missing.stdout.is_empty());
    assert_eq!(missing.stderr, b"model_missing\n");
    assert_eq!(fs::read(&path).unwrap(), wav);
    fs::write(&path, b"PRIVATE_MALFORMED_AUDIO_CANARY").unwrap();
    let invalid = invoke();
    assert_eq!(invalid.status.code(), Some(2));
    assert!(invalid.stdout.is_empty());
    assert_eq!(invalid.stderr, b"invalid_audio\n");
    assert_eq!(fs::read(&path).unwrap(), b"PRIVATE_MALFORMED_AUDIO_CANARY");
    send(&mut c, json!({"version":1,"type":"stop"}));
    assert_eq!(receive(&mut c)["type"], "stopped");
}

#[test]
fn cli_terminal_wait_empty_identity_errors_and_sigint_never_deliver_late_text() {
    use std::os::unix::fs::PermissionsExt;
    use std::os::unix::net::UnixListener;

    // A controlled public peer tests the client, not inference or adoption.
    let mut service = Service::new("client");
    let mut c = service.client();
    send(&mut c, json!({"version":1,"type":"hello"}));
    receive(&mut c);
    send(&mut c, json!({"version":1,"type":"stop"}));
    assert_eq!(receive(&mut c)["type"], "stopped");
    assert!(service.child.wait().unwrap().success());
    let socket = service.root.join("hagig/server.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    fs::set_permissions(&socket, fs::Permissions::from_mode(0o600)).unwrap();
    let path = service.root.join("input.wav");
    let wav = [
        b"RIFF".as_slice(),
        &38_u32.to_le_bytes(),
        b"WAVEfmt ",
        &16_u32.to_le_bytes(),
        &1_u16.to_le_bytes(),
        &1_u16.to_le_bytes(),
        &16_000_u32.to_le_bytes(),
        &32_000_u32.to_le_bytes(),
        &2_u16.to_le_bytes(),
        &16_u16.to_le_bytes(),
        b"data",
        &2_u32.to_le_bytes(),
        &(-4096_i16).to_le_bytes(),
    ]
    .concat();
    fs::write(&path, &wav).unwrap();
    let (pending, ready) = std::sync::mpsc::channel();
    let peer = std::thread::spawn(move || {
        let fixture: Value =
            serde_json::from_str(include_str!("fixtures/protocol-v1-fixtures.json")).unwrap();
        for case in 0..7 {
            let (mut c, _) = listener.accept().unwrap();
            c.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
            c.set_write_timeout(Some(Duration::from_secs(5))).unwrap();
            assert_eq!(receive(&mut c), json!({"version":1,"type":"hello"}));
            send(&mut c, fixture["control_templates"]["hello_ok"].clone());
            assert_eq!(
                receive(&mut c),
                json!({"version":1,"type":"begin","request_id":"cli"})
            );
            let mut accepted = fixture["control_templates"]["accepted"].clone();
            accepted["request_id"] = json!("cli");
            send(&mut c, accepted);
            let mut pcm = [0; 9];
            c.read_exact(&mut pcm).unwrap();
            assert_eq!(pcm, [2, 0, 0, 0, 4, 0, 0, 0, 190]);
            assert_eq!(
                receive(&mut c),
                json!({"version":1,"type":"end_audio","request_id":"cli"})
            );
            if case == 0 {
                std::thread::sleep(Duration::from_secs(6));
            }
            if case == 4 {
                pending.send(()).unwrap();
                // Let the client observe SIGINT and close before a late result.
                assert_eq!(c.read(&mut [0; 1]).unwrap(), 0);
                let _ = c.write_all(b"LATE_RESULT_MUST_NOT_ESCAPE");
                continue;
            }
            if case >= 5 {
                let bytes = if case == 5 {
                    br#"{"version":1,"type":"result","request_id":"wrong","request_id":"cli","text":"MUST_NOT_ESCAPE"}"#.as_slice()
                } else {
                    br#"{"version":1,"type":"result","request_id":"cli","text":"MUST_NOT_ESCAPE","extra":{"key":1,"key":2}}"#.as_slice()
                };
                c.write_all(&[&[1][..], &(bytes.len() as u32).to_be_bytes(), bytes].concat())
                    .unwrap();
                continue;
            }
            let result = if case == 3 {
                json!({"version":1,"type":"error","request_id":"cli","code":"worker_failed"})
            } else {
                json!({"version":1,"type":"result","request_id":if case == 2 {"wrong"} else {"cli"},"text":if case == 1 {" \n\t"} else {"Fixture λ.\nNext."}})
            };
            send(&mut c, result);
        }
    });
    for case in 0..7 {
        let mut child = Command::new(env!("CARGO_BIN_EXE_hagig"))
            .env("XDG_RUNTIME_DIR", &service.root)
            .arg("transcribe")
            .arg(&path)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        if case == 4 {
            ready.recv_timeout(Duration::from_secs(5)).unwrap();
            assert!(
                Command::new("/bin/kill")
                    .args(["-s", "INT", &child.id().to_string()])
                    .status()
                    .unwrap()
                    .success()
            );
        }
        let deadline = Instant::now() + Duration::from_secs(10);
        while child.try_wait().unwrap().is_none() {
            if Instant::now() >= deadline {
                let _ = child.kill();
                let _ = child.wait();
                panic!("CLI did not terminate for case {case}");
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        let output = child.wait_with_output().unwrap();
        assert_eq!(output.status.code(), Some([0, 0, 1, 1, 130, 1, 1][case]));
        assert_eq!(
            output.stdout,
            if case == 0 {
                "Fixture λ.\nNext.\n".as_bytes()
            } else {
                b""
            }
        );
        assert_eq!(
            output.stderr,
            [
                b"".as_slice(),
                b"",
                b"incompatible_protocol\n",
                b"worker_failed\n",
                b"interrupted\n",
                b"incompatible_protocol\n",
                b"incompatible_protocol\n"
            ][case]
        );
        assert_eq!(fs::read(&path).unwrap(), wav, "input is caller-owned");
    }
    peer.join().unwrap();
}

#[test]
fn real_private_exchange_checks_framing_limits_warm_reuse_and_cancel_recovery() {
    use std::os::unix::fs::PermissionsExt;
    let mut service = Service::new("private");
    let mut c = service.client();
    send(&mut c, json!({"version":1,"type":"hello"}));
    receive(&mut c);
    send(&mut c, json!({"version":1,"type":"stop"}));
    receive(&mut c);
    assert!(service.child.wait().unwrap().success());
    let bin = service.root.join("bin");
    fs::create_dir(&bin).unwrap();
    fs::copy(env!("CARGO_BIN_EXE_hagig"), bin.join("hagig")).unwrap();
    fs::copy(env!("CARGO_BIN_EXE_hagig-worker"), bin.join("hagig-worker")).unwrap();
    assert!(
        Command::new("rustc")
            .args(["--edition=2024", "-Dwarnings"])
            .arg(
                std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                    .join("tests/fixtures/inference_peer.rs")
            )
            .arg("-o")
            .arg(bin.join("hagig-inference-worker"))
            .status()
            .unwrap()
            .success()
    );
    let model = service
        .root
        .join("data/hagig/models/parakeet-tdt-0.6b-v2-int8-v1");
    fs::create_dir_all(&model).unwrap();
    fs::set_permissions(&model, fs::Permissions::from_mode(0o700)).unwrap();
    fs::write(
        service.root.join("config/hagig/config.toml"),
        "[inference]\nnetwork_isolation='disabled'",
    )
    .unwrap();
    service.child = Command::new(bin.join("hagig"))
        .env("XDG_RUNTIME_DIR", &service.root)
        .env("XDG_CONFIG_HOME", service.root.join("config"))
        .env("XDG_DATA_HOME", service.root.join("data"))
        .arg("__serve")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while !service.root.join("hagig/server.sock").exists() {
        assert!(service.child.try_wait().unwrap().is_none());
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(5));
    }
    let mut owner = service.client();
    send(&mut owner, json!({"version":1,"type":"hello"}));
    assert_eq!(receive(&mut owner)["worker"], "inference");
    let mut observer = service.client();
    send(&mut observer, json!({"version":1,"type":"hello"}));
    receive(&mut observer);
    let status = |c: &mut UnixStream| {
        send(c, json!({"version":1,"type":"status"}));
        receive(c)
    };
    let upload = |c: &mut UnixStream, id: &str| {
        send(c, json!({"version":1,"type":"begin","request_id":id}));
        assert_eq!(receive(c)["type"], "accepted");
        c.write_all(&[&[2][..], &4_u32.to_be_bytes(), &0.125_f32.to_le_bytes()].concat())
            .unwrap();
        send(c, json!({"version":1,"type":"end_audio","request_id":id}));
    };
    upload(&mut owner, "warm");
    assert_eq!(receive(&mut owner)["text"], "Fixture");
    let first = status(&mut observer)["worker_pid"].as_u64().unwrap();
    upload(&mut owner, "fragmented");
    assert_eq!(receive(&mut owner)["text"], "Fixture");
    assert_eq!(status(&mut observer)["worker_pid"], first);
    upload(&mut owner, "max");
    let max = receive(&mut owner);
    assert_eq!(max["type"], "result");
    assert_eq!(serde_json::to_vec(&max).unwrap().len(), 65_536);
    upload(&mut owner, "oversize");
    assert_eq!(receive(&mut owner)["code"], "result_too_large");
    for code in ["model_invalid", "model_missing", "result_too_large"] {
        upload(&mut owner, code);
        assert_eq!(
            receive(&mut owner)["code"],
            code,
            "complete terminal error followed by worker exit"
        );
        assert!(status(&mut observer)["worker_pid"].is_null());
    }
    for id in ["wrong", "excess", "crash"] {
        upload(&mut owner, id);
        let failure = receive(&mut owner);
        assert_eq!(failure["type"], "error", "{id} must not deliver text");
        assert_eq!(failure["code"], "worker_failed");
        assert!(status(&mut observer)["worker_pid"].is_null());
        upload(&mut owner, "warm");
        assert_eq!(receive(&mut owner)["text"], "Fixture");
    }
    upload(&mut owner, "stall");
    let deadline = Instant::now() + Duration::from_secs(5);
    let pid = loop {
        if let Some(pid) = status(&mut observer)["worker_pid"].as_u64() {
            break pid;
        }
        assert!(Instant::now() < deadline);
    };
    assert!(
        Command::new("/bin/kill")
            .args(["-0", &pid.to_string()])
            .status()
            .unwrap()
            .success()
    );
    send(
        &mut owner,
        json!({"version":1,"type":"cancel","request_id":"stall"}),
    );
    assert_eq!(receive(&mut owner)["type"], "cancelled");
    while status(&mut observer)["state"] != "idle" {
        assert!(Instant::now() < deadline);
    }
    assert!(
        !Command::new("/bin/kill")
            .args(["-0", &pid.to_string()])
            .stderr(Stdio::null())
            .status()
            .unwrap()
            .success()
    );
    upload(&mut owner, "warm");
    let recovered = receive(&mut owner);
    assert_eq!(recovered["type"], "result");
    assert_eq!(recovered["request_id"], "warm");
    assert_eq!(recovered["text"], "Fixture");
    assert_ne!(status(&mut observer)["worker_pid"], pid);
    send(&mut owner, json!({"version":1,"type":"stop"}));
    assert_eq!(receive(&mut owner)["type"], "stopped");
    assert!(service.child.wait().unwrap().success());
}

#[cfg(target_os = "macos")]
#[test]
fn inherited_macos_tmpdir_is_required_private_and_not_a_symlink() {
    use std::os::unix::fs::{PermissionsExt, symlink};

    let root = std::env::temp_dir().join(format!("hg-tmp-{}", std::process::id()));
    fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
    let invoke = |tmpdir: Option<&std::path::Path>| {
        let mut command = Command::new(env!("CARGO_BIN_EXE_hagig"));
        command.env_remove("XDG_RUNTIME_DIR").env_remove("TMPDIR");
        if let Some(tmpdir) = tmpdir {
            command.env("TMPDIR", tmpdir);
        }
        command.arg("status").output().unwrap()
    };
    let valid = invoke(Some(&root));
    assert!(valid.status.success());
    assert_eq!(valid.stdout, b"stopped\n");
    assert!(valid.stderr.is_empty());
    let link = root.with_extension("link");
    symlink(&root, &link).unwrap();
    for path in [
        None,
        Some(link.as_path()),
        Some(std::path::Path::new("relative")),
        Some(std::path::Path::new("")),
    ] {
        let output = invoke(path);
        assert_eq!(output.status.code(), Some(1));
        assert!(output.stdout.is_empty());
        assert_eq!(output.stderr, b"unsafe_runtime\n");
    }
    fs::set_permissions(&root, fs::Permissions::from_mode(0o755)).unwrap();
    let public = invoke(Some(&root));
    assert_eq!(public.status.code(), Some(1));
    assert_eq!(public.stderr, b"unsafe_runtime\n");
    assert!(public.stdout.is_empty());
    fs::remove_file(link).unwrap();
    fs::remove_dir(root).unwrap();
}
