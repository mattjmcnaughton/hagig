#![cfg(target_os = "linux")]

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::os::fd::AsRawFd;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdout, Command, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use hagig::launcher::{
    LaunchError, NetworkIsolation, PlatformLauncher, SandboxedWorkerLauncher, WorkerExecutable,
};
use hagig::supervisor::{Supervisor, SupervisorError};

struct Fixture(PathBuf);

impl Fixture {
    fn compile() -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let directory = Path::new(env!("CARGO_TARGET_TMPDIR")).join(format!(
            "linux-isolation-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(directory.parent().unwrap()).unwrap();
        // Refuse a stale/symlink directory rather than overwriting anything.
        std::fs::create_dir(&directory).unwrap();
        let fixture = Self(directory);
        let status = Command::new("rustc")
            .args([
                "--edition=2024",
                "-Dwarnings",
                "--crate-name",
                "hagig_linux_test_worker",
            ])
            .arg(Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/linux_worker.rs"))
            .arg("-o")
            .arg(fixture.0.join("worker"))
            .status()
            .unwrap();
        assert!(
            status.success(),
            "pinned rustc must compile the std-only fixture"
        );
        for name in [
            "bad-worker",
            "suffix-worker",
            "truncated-worker",
            "drip-worker",
            "fragmented-worker",
            "stall-worker",
            "exit-worker",
        ] {
            std::os::unix::fs::symlink(fixture.0.join("worker"), fixture.0.join(name)).unwrap();
        }
        fixture
    }

    fn launcher(&self, name: &str) -> PlatformLauncher {
        PlatformLauncher::new(WorkerExecutable::new(self.0.join(name)).unwrap())
    }

    fn pid(&self, name: &str) -> u32 {
        std::fs::read_to_string(self.0.join(name).with_extension("pid"))
            .unwrap()
            .parse()
            .unwrap()
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        std::fs::remove_dir_all(&self.0).unwrap();
    }
}

fn report(output: ChildStdout) -> HashMap<String, String> {
    let (sender, receiver) = mpsc::channel();
    let reader = std::thread::spawn(move || {
        let mut report = HashMap::new();
        for line in BufReader::new(output).lines() {
            let line = line.unwrap();
            if line == "END" {
                sender.send(report).unwrap();
                return;
            }
            let (key, value) = line
                .split_once('=')
                .expect("only worker protocol follows ACK");
            report.insert(key.to_string(), value.to_string());
        }
    });
    let report = receiver.recv_timeout(Duration::from_secs(5)).unwrap();
    reader.join().unwrap();
    report
}

fn exists(pid: u32) -> bool {
    // Includes zombies: absence after stop proves reap, not merely termination.
    Path::new(&format!("/proc/{pid}")).exists()
}

fn expect_launch_failure(result: Result<Child, LaunchError>) -> LaunchError {
    match result {
        Err(error) => error,
        Ok(mut child) => {
            // Keep a failing regression from leaking the unexpected child.
            let _ = child.kill();
            let _ = child.wait();
            panic!("launch unexpectedly succeeded");
        }
    }
}

#[test]
fn linux_worker_isolation_and_failure_contract() {
    worker_contract(NetworkIsolation::Required);
}

#[test]
fn disabled_worker_hygiene_and_failure_contract() {
    worker_contract(NetworkIsolation::Disabled);
}

fn worker_contract(isolation: NetworkIsolation) {
    const CAPTURED: &str = "HAGIG_TEST_ISOLATION_CAPTURED";
    if std::env::var_os(CAPTURED).is_none() {
        // Observe inherited stderr at the process boundary: Child::stderr=None
        // alone cannot distinguish suppressed diagnostics from inherited ones.
        let test = match isolation {
            NetworkIsolation::Required => "linux_worker_isolation_and_failure_contract",
            NetworkIsolation::Disabled => "disabled_worker_hygiene_and_failure_contract",
        };
        let output = Command::new(std::env::current_exe().unwrap())
            .args(["--exact", test, "--nocapture"])
            .env(CAPTURED, "1")
            .output()
            .unwrap();
        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(!stdout.contains("HAGIG_TEST_DIAGNOSTIC_CANARY"));
        assert!(!stderr.contains("HAGIG_TEST_DIAGNOSTIC_CANARY"));
        assert!(output.status.success(), "{stdout}\n{stderr}");
        eprint!("{stdout}{stderr}");
        return;
    }
    let fixture = Fixture::compile();
    let launcher = |name| fixture.launcher(name).with_network_isolation(isolation);
    let ipv4 = TcpListener::bind("127.0.0.1:0").unwrap();
    let ipv6 = TcpListener::bind("[::1]:0").expect("UNSUPPORTED: host IPv6 loopback unavailable");
    let connected_socket = TcpStream::connect(ipv4.local_addr().unwrap()).unwrap();
    // Deliberately create a preconnected inheritable socket: ordinary std sockets
    // are CLOEXEC and would not catch a launcher that forgot descriptor hygiene.
    let inherited_socket = rustix::io::fcntl_dupfd_cloexec(&connected_socket, 200).unwrap();
    rustix::io::fcntl_setfd(&inherited_socket, rustix::io::FdFlags::empty()).unwrap();
    let fd = inherited_socket.as_raw_fd();
    let input = format!(
        "{} {} {fd}\n",
        ipv4.local_addr().unwrap(),
        ipv6.local_addr().unwrap()
    );
    let parent_namespace = std::fs::read_link("/proc/self/ns/net").unwrap();

    // The exact same target/endpoints must work both before and after the denied
    // cases. General network outage or missing IPv6 cannot masquerade as proof.
    for round in 0..=2 {
        let mut control = Command::new(fixture.0.join("worker"))
            .env("HTTP_PROXY", "synthetic-proxy-canary.invalid")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let mut output = control.stdout.take().unwrap();
        let mut ack = [0; 22];
        // Contract bytes are independent of the implementation's ACK constant.
        let expected = b"HAGIG-WORKER-READY-v1\n";
        output.read_exact(&mut ack[..expected.len()]).unwrap();
        assert_eq!(&ack[..expected.len()], expected);
        let mut control_input = control.stdin.take().unwrap();
        control_input.write_all(input.as_bytes()).unwrap();
        let control_report = report(output);
        assert_eq!(control_report["ipv4"], "connected");
        assert_eq!(control_report["ipv6"], "connected");
        assert_eq!(control_report["netns"], parent_namespace.to_str().unwrap());
        assert_eq!(control_report["boot_netns"], control_report["netns"]);
        assert_eq!(control_report["inherited_fd"], "true");
        assert!(control_report["env_count"].parse::<usize>().unwrap() > 0);
        drop(control_input);
        assert!(control.wait().unwrap().success());
        let mut diagnostic = String::new();
        control
            .stderr
            .take()
            .unwrap()
            .read_to_string(&mut diagnostic)
            .unwrap();
        assert_eq!(diagnostic, "HAGIG_TEST_DIAGNOSTIC_CANARY\n");
        assert!(!exists(control.id()));
        eprintln!("round={round}: unrestricted IPv4/IPv6 positive controls passed");
        if round == 2 {
            break;
        }

        let selected = launcher("worker");
        assert_eq!(selected.network_isolation(), isolation);
        eprintln!("selected network isolation={isolation}");
        let mut supervisor = Supervisor::new(selected);
        for generation in 0..2 {
            let mut pipes = match supervisor.start() {
                Ok(pipes) => pipes,
                Err(SupervisorError::Launch(LaunchError::IsolationUnavailable)) => {
                    panic!(
                        "UNSUPPORTED: Linux user/network namespaces, proc maps/FDs or bootstrap unavailable; NOT an isolation pass"
                    );
                }
                Err(error) => panic!("isolated launch failed: {error}"),
            };
            pipes.input.write_all(input.as_bytes()).unwrap();
            let isolated = report(pipes.output);
            assert_eq!(isolated["boot_netns"], isolated["netns"]);
            // Fresh namespace has no configured routes and loopback is down.
            // IPv6 can fail earlier for lack of a usable source address. Require
            // these specific kernel reasons, not arbitrary connect failures.
            match isolation {
                NetworkIsolation::Required => {
                    assert_ne!(isolated["netns"], parent_namespace.to_str().unwrap());
                    assert_eq!(isolated["ipv4"], "errno:101");
                    assert!(matches!(
                        isolated["ipv6"].as_str(),
                        "errno:99" | "errno:101"
                    ));
                }
                NetworkIsolation::Disabled => {
                    assert_eq!(isolated["netns"], parent_namespace.to_str().unwrap());
                    assert_eq!(isolated["ipv4"], "connected");
                    assert_eq!(isolated["ipv6"], "connected");
                }
            }
            assert_eq!(isolated["inherited_fd"], "false");
            assert_eq!(isolated["env_count"], "0");
            assert_eq!(isolated["cwd_root"], "true");
            assert_eq!(isolated["no_new_privs"], "true");
            let pid: u32 = isolated["pid"].parse().unwrap();
            assert!(exists(pid));
            assert!(matches!(
                supervisor.start(),
                Err(SupervisorError::AlreadyRunning)
            ));
            supervisor.stop().unwrap();
            assert!(
                !exists(pid),
                "stopped child must be reaped before successor"
            );
            drop(pipes.input);
            eprintln!(
                "round={round} generation={generation}: isolation={isolation}; worker IPv4={} IPv6={}; inherited socket removed; empty env; no_new_privs; kill/reap passed",
                isolated["ipv4"], isolated["ipv6"]
            );
        }
        let mut pipes = supervisor.start().unwrap();
        pipes.input.write_all(input.as_bytes()).unwrap();
        let isolated = report(pipes.output);
        let pid: u32 = isolated["pid"].parse().unwrap();
        drop(supervisor);
        assert!(
            !exists(pid),
            "Drop must terminate and reap a live isolated worker"
        );
        drop(pipes.input);
    }

    let mut fragmented = Supervisor::new(launcher("fragmented-worker"));
    let mut pipes = fragmented.start().unwrap();
    pipes.input.write_all(input.as_bytes()).unwrap();
    let response = report(pipes.output);
    assert_eq!(response["boot_netns"], response["netns"]);
    if isolation == NetworkIsolation::Required {
        assert_ne!(response["netns"], parent_namespace.to_str().unwrap());
        assert_eq!(response["ipv4"], "errno:101");
    } else {
        assert_eq!(response["netns"], parent_namespace.to_str().unwrap());
        assert_eq!(response["ipv4"], "connected");
    }
    let pid = response["pid"].parse().unwrap();
    fragmented.stop().unwrap();
    assert!(!exists(pid));
    drop(pipes.input);
    eprintln!("fragmented ACK: accepted; following protocol preserved; child reaped");

    assert_eq!(
        expect_launch_failure(launcher("missing-worker").launch()),
        LaunchError::SpawnFailed
    );
    for mode in [
        "bad-worker",
        "suffix-worker",
        "truncated-worker",
        "exit-worker",
        "stall-worker",
        "drip-worker",
    ] {
        let start = Instant::now();
        assert_eq!(
            expect_launch_failure(launcher(mode).launch()),
            LaunchError::WorkerNotReady
        );
        assert!(
            start.elapsed() < Duration::from_secs(7),
            "startup ACK deadline must be bounded"
        );
        assert!(
            !exists(fixture.pid(mode)),
            "failed bootstrap must be killed and reaped"
        );
        eprintln!(
            "{mode}: safe startup error; child reaped; elapsed={:?}",
            start.elapsed()
        );
    }
    assert!(
        launcher("worker").launch().is_ok_and(|mut child| {
            child.kill().unwrap();
            child.wait().unwrap();
            !exists(child.id())
        }),
        "valid launch after all startup failures must recover"
    );
}

#[test]
fn required_mode_reports_enforcement_or_refusal() {
    let fixture = Fixture::compile();
    let launcher = fixture.launcher("worker");
    assert_eq!(launcher.network_isolation(), NetworkIsolation::Required);
    let mut supervisor = Supervisor::new(launcher);
    match supervisor.start() {
        Ok(pipes) => {
            let (sender, receiver) = mpsc::channel();
            let reader = std::thread::spawn(move || {
                let mut output = BufReader::new(pipes.output);
                let mut boot_namespace = String::new();
                output.read_line(&mut boot_namespace).unwrap();
                sender.send(boot_namespace).unwrap();
            });
            let boot_namespace = receiver.recv_timeout(Duration::from_secs(5)).unwrap();
            let pid = fixture.pid("worker");
            supervisor.stop().unwrap();
            reader.join().unwrap();
            assert!(!exists(pid));
            assert_ne!(
                boot_namespace.trim(),
                format!(
                    "boot_netns={}",
                    std::fs::read_link("/proc/self/ns/net").unwrap().display()
                )
            );
            eprintln!(
                "required mode: distinct namespace; full network enforcement proof is a separate gate"
            );
        }
        Err(SupervisorError::Launch(LaunchError::IsolationUnavailable)) => {
            assert!(!fixture.0.join("worker.pid").exists());
            eprintln!(
                "required mode: host refused isolation; target never executed; NOT enforcement proof"
            );
        }
        Err(error) => panic!("unexpected launch failure: {error}"),
    }
}

#[test]
fn unmapped_user_namespace_fails_closed() {
    const TARGET: &str = "HAGIG_TEST_DENIED_NAMESPACE_WORKER";
    if let Some(path) = std::env::var_os(TARGET) {
        let path = PathBuf::from(path);
        let launcher = PlatformLauncher::new(WorkerExecutable::new(&path).unwrap());
        assert_eq!(
            expect_launch_failure(launcher.launch()),
            LaunchError::IsolationUnavailable
        );
        assert!(
            !path.with_extension("pid").exists(),
            "denied isolation must not exec the worker"
        );
        eprintln!(
            "kernel-denied nested user namespace: safe IsolationUnavailable; worker never executed"
        );
        return;
    }
    let fixture = Fixture::compile();
    let mut command = Command::new(std::env::current_exe().unwrap());
    command
        .args([
            "--exact",
            "unmapped_user_namespace_fails_closed",
            "--nocapture",
        ])
        .env(TARGET, fixture.0.join("worker"));
    // SAFETY: Only a Linux syscall in this single-threaded post-fork child.
    // Deliberately omit uid_map: Linux forbids creating a descendant user
    // namespace when the creator's uid has no mapping in its current namespace.
    // The production launcher must report that REAL kernel denial, not retry
    // unrestricted. This does not change the parent/host namespace or policy.
    unsafe {
        command.pre_exec(|| {
            rustix::thread::unshare_unsafe(rustix::thread::UnshareFlags::NEWUSER)
                .map_err(std::io::Error::from)
        });
    }
    let status = command
        .status()
        .expect("UNSUPPORTED: host denies user namespace test setup");
    assert!(
        status.success(),
        "kernel-denial subprocess must exercise fail-closed handling"
    );
    assert!(!fixture.0.join("worker.pid").exists());
}
