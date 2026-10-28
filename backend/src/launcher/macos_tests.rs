use super::*;
use crate::launcher::{PlatformLauncher, WORKER_READY as READY};
use crate::supervisor::Supervisor;
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::net::{TcpListener, TcpStream};
use std::os::fd::AsRawFd;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::sync::{
    atomic::{AtomicU64, Ordering},
    mpsc,
};
use std::time::{Duration, Instant};

struct Fixture(PathBuf);

impl Fixture {
    fn directory() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let path = std::env::temp_dir().join(format!(
            "hagig-seatbelt-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        // Exclusive creation: never reuse an existing directory or follow it.
        std::fs::DirBuilder::new()
            .mode(0o700)
            .create(&path)
            .unwrap();
        Self(path)
    }

    fn script(body: &str) -> Self {
        let fixture = Self::directory();
        let path = fixture.0.join("worker");
        fs::write(
            &path,
            format!(
                "#!/bin/sh\nprintf '%s' \"$$\" > '{}'/pid\n{body}\n",
                fixture.0.display()
            ),
        )
        .unwrap();
        fs::set_permissions(path, fs::Permissions::from_mode(0o700)).unwrap();
        fixture
    }

    fn worker(&self) -> WorkerExecutable {
        WorkerExecutable::new(self.0.join("worker")).unwrap()
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

use std::os::unix::fs::DirBuilderExt;

fn probe() -> Fixture {
    let fixture = Fixture::directory();
    let source = fixture.0.join("probe.rs");
    fs::write(&source, include_str!("seatbelt_probe.rs")).unwrap();
    let status = Command::new("rustc")
        .arg("--edition=2024")
        .arg(&source)
        .arg("-o")
        .arg(fixture.0.join("worker"))
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .unwrap();
    assert!(status.success(), "synthetic probe compilation failed");
    fixture
}

fn exchange<W: Write, R: BufRead>(input: &mut W, output: &mut R, request: &str) -> String {
    writeln!(input, "{request}").unwrap();
    input.flush().unwrap();
    let mut line = String::new();
    output.read_line(&mut line).unwrap();
    line.trim_end().to_owned()
}

#[test]
fn controlled_network_and_private_pipes() {
    // Inject parent contamination in a dedicated subprocess, not by racing
    // unsafe set_var against parallel tests. Do not print env values.
    const NAME: &str = "launcher::macos::tests::controlled_network_and_private_pipes";
    if std::env::var_os("HAGIG_ISOLATION_SENTINEL").is_none() {
        let result = Command::new(std::env::current_exe().unwrap())
            .args(["--exact", NAME, "--nocapture"])
            .env("HAGIG_ISOLATION_SENTINEL", "synthetic")
            .env("HTTP_PROXY", "synthetic-invalid-proxy")
            .env("https_proxy", "synthetic-invalid-proxy")
            .status()
            .unwrap();
        assert!(result.success(), "controlled isolation subprocess failed");
        return;
    }

    let fixture = probe();
    // Real listeners outside the sandbox. IPv6 is mandatory: unavailable means
    // a failed gate, not a skipped test or a misleading successful report.
    let ipv4 = TcpListener::bind("127.0.0.1:0").unwrap();
    let ipv6 = TcpListener::bind("[::1]:0").unwrap();
    let connected = TcpStream::connect(ipv4.local_addr().unwrap()).unwrap();
    // Duplicate then explicitly clear CLOEXEC for an inheritable high connected
    // socket. Positive control below must see it, or this hygiene test is void.
    let inherited = rustix::io::fcntl_dupfd_cloexec(&connected, 200).unwrap();
    rustix::io::fcntl_setfd(&inherited, rustix::io::FdFlags::empty()).unwrap();
    let raw = inherited.as_raw_fd();
    assert!(raw >= 200);

    let mut positive = Command::new(fixture.worker().path())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut positive_input = positive.stdin.take().unwrap();
    let mut positive_output = BufReader::new(positive.stdout.take().unwrap());
    let mut ack = String::new();
    positive_output.read_line(&mut ack).unwrap();
    assert_eq!(ack.as_bytes(), READY);
    for listener in [&ipv4, &ipv6] {
        assert_eq!(
            exchange(
                &mut positive_input,
                &mut positive_output,
                &format!("connect {}", listener.local_addr().unwrap())
            ),
            "connected"
        );
        // The listeners remain open outside both workers for the entire test.
    }
    assert_eq!(
        exchange(
            &mut positive_input,
            &mut positive_output,
            &format!("fd {raw}")
        ),
        "inherited"
    );
    assert_eq!(
        exchange(&mut positive_input, &mut positive_output, "environment"),
        "contaminated"
    );
    writeln!(positive_input, "exit").unwrap();
    assert!(positive.wait().unwrap().success());

    let commands = [
        format!("connect {}", ipv4.local_addr().unwrap()),
        format!("connect {}", ipv6.local_addr().unwrap()),
        format!("fd {raw}"),
        "environment".into(),
        "cwd".into(),
    ];
    for mode in [NetworkIsolation::Required, NetworkIsolation::Disabled] {
        let launcher = PlatformLauncher::new(fixture.worker());
        // Exercise the default Required constructor, not an explicit Required
        // override that could hide a regressed default.
        let launcher = match mode {
            NetworkIsolation::Required => launcher,
            NetworkIsolation::Disabled => launcher.with_network_isolation(mode),
        };
        assert_eq!(launcher.network_isolation(), mode);
        let mut supervisor = Supervisor::new(launcher);
        let mut pipes = supervisor.start().unwrap();
        let (sender, receiver) = mpsc::channel();
        let commands = commands.clone();
        let reader = std::thread::spawn(move || {
            let mut output = BufReader::new(pipes.output);
            let mut results = Vec::new();
            for command in commands {
                results.push(exchange(&mut pipes.input, &mut output, &command));
            }
            sender.send(results).unwrap();
        });
        // A blocked pipe/network regression fails, not an unbounded CI hang.
        // Drop kills the worker on panic; the workflow has an outer time bound.
        let results = receiver.recv_timeout(Duration::from_secs(8)).unwrap();
        let network = match mode {
            NetworkIsolation::Required => "permission-denied",
            NetworkIsolation::Disabled => "connected",
        };
        assert_eq!(results, [network, network, "closed", "clean", "root"]);
        supervisor.stop().unwrap();
        reader.join().unwrap();
        println!(
            "seatbelt-evidence-v1: mode={mode} ipv4={network} ipv6={network} private_pipes=pass inherited_socket=closed environment=clean cwd=root"
        );
    }
    drop(inherited);
    println!(
        "seatbelt-evidence-v1: ipv4_control=connected ipv6_control=connected required_default=pass explicit_disabled=pass no_disabled_network_block_claim"
    );
}

#[test]
fn invalid_policy_and_missing_executables_fail_closed() {
    let fixture = probe();
    let worker = fixture.worker();
    for policy in ["not a Seatbelt profile", "(version 1) (deny default)"] {
        let error = launch_with(
            &worker,
            NetworkIsolation::Required,
            Path::new("/usr/bin/sandbox-exec"),
            policy,
        )
        .err()
        .unwrap();
        assert_eq!(error, LaunchError::WorkerNotReady);
        assert_eq!(error.to_string(), "worker readiness check failed");
    }
    assert_eq!(
        launch_with(
            &worker,
            NetworkIsolation::Required,
            Path::new("/nonexistent-hagig/sandbox-exec"),
            POLICY
        )
        .err(),
        Some(LaunchError::SpawnFailed)
    );
    let absent = WorkerExecutable::new("/nonexistent-hagig/sensitive-worker").unwrap();
    assert_eq!(
        launch(&absent, NetworkIsolation::Required).err(),
        Some(LaunchError::WorkerNotReady)
    );
    assert_eq!(
        launch(&absent, NetworkIsolation::Disabled).err(),
        Some(LaunchError::SpawnFailed)
    );
    println!(
        "seatbelt-evidence-v1: invalid_policy=refused denied_exec=refused missing_tool=refused missing_target=refused sanitized_errors=pass"
    );
}

#[test]
fn invalid_and_missing_ready_are_reaped_before_error() {
    // Positive control: signal-0 observation itself must work on this host.
    assert!(
        Command::new("/bin/kill")
            .args(["-0", &std::process::id().to_string()])
            .stderr(Stdio::null())
            .status()
            .unwrap()
            .success()
    );
    for mode in [NetworkIsolation::Required, NetworkIsolation::Disabled] {
        for body in [
            "printf 'wrong-ready\\n'; while :; do :; done",
            "printf 'HAGIG-WORKER-READY-v2\\n'; while :; do :; done",
            "while :; do :; done",
            "exit 0",
            "printf 'HAGIG-'; while :; do :; done",
            // Progress every two seconds must not reset the five-second total
            // deadline. read -t is a /bin/sh builtin, not an unsupervised child.
            "printf H; IFS= read -r -t 2 unused || :; printf A; IFS= read -r -t 2 unused || :; printf G; IFS= read -r -t 2 unused || :; printf 'IG-WORKER-READY-v1\\n'; while :; do :; done",
        ] {
            let fixture = Fixture::script(body);
            let before = Instant::now();
            let error = match launch(&fixture.worker(), mode) {
                Err(error) => error,
                Ok(mut child) => {
                    // A regressed deadline must not leak the accepted busy fixture.
                    let _ = child.kill();
                    let _ = child.wait();
                    panic!("invalid bootstrap unexpectedly became ready");
                }
            };
            assert_eq!(error, LaunchError::WorkerNotReady);
            assert_eq!(error.to_string(), "worker readiness check failed");
            assert!(before.elapsed() < Duration::from_secs(7));
            let pid = fs::read_to_string(fixture.0.join("pid")).unwrap();
            assert!(
                !Command::new("/bin/kill")
                    .args(["-0", &pid])
                    .stderr(Stdio::null())
                    .status()
                    .unwrap()
                    .success(),
                "failed bootstrap was not reaped"
            );
        }
    }
    println!(
        "seatbelt-evidence-v1: malformed_ready=refused absent_ready=refused startup_deadline=bounded"
    );
}
