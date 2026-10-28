#![cfg(unix)]

use std::io::{Read, Write};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex, mpsc};
use std::time::Duration;

use hagig::launcher::{
    LaunchError, NetworkIsolation, PlatformLauncher, SandboxedWorkerLauncher, WorkerExecutable,
};
use hagig::supervisor::{Supervisor, SupervisorError};

// Unrestricted fixtures are compiled ONLY into this integration test binary.
// Shell builtins only: no model, network, credentials, files or descendants.
struct ControlledLauncher {
    program: &'static str,
    script: &'static str,
    piped: bool,
    pids: Arc<Mutex<Vec<u32>>>,
}

impl ControlledLauncher {
    fn echo() -> Self {
        Self {
            program: "/bin/sh",
            script: "IFS= read -r line; printf 'reply:%s' \"$line\"",
            piped: true,
            pids: Arc::default(),
        }
    }
}

impl SandboxedWorkerLauncher for ControlledLauncher {
    fn launch(&self) -> Result<Child, LaunchError> {
        let child = Command::new(self.program)
            .args(["-c", self.script])
            .env_clear()
            .stdin(if self.piped {
                Stdio::piped()
            } else {
                Stdio::null()
            })
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|_| LaunchError::SpawnFailed)?;
        self.pids.lock().unwrap().push(child.id());
        Ok(child)
    }
}

// Signal 0 observes existence without signalling a process. A zombie still
// exists, so this checks reaping, not merely closed output pipes.
fn process_exists(pid: u32) -> bool {
    Command::new("/bin/kill")
        .args(["-0", &pid.to_string()])
        .stderr(Stdio::null())
        .status()
        .unwrap()
        .success()
}

fn assert_reaped(pids: &Mutex<Vec<u32>>) {
    for &pid in pids.lock().unwrap().iter() {
        assert!(!process_exists(pid), "child {pid} still exists");
    }
}

#[test]
fn private_ipc_and_relaunch_after_reap() {
    let launcher = ControlledLauncher::echo();
    let pids = launcher.pids.clone();
    let mut supervisor = Supervisor::new(launcher);
    for request in ["first asymmetric fixture", "second request"] {
        let mut pipes = supervisor.start().unwrap();
        assert!(matches!(
            supervisor.start(),
            Err(SupervisorError::AlreadyRunning)
        ));
        let (sender, receiver) = mpsc::channel();
        let reader = std::thread::spawn(move || {
            let mut output = String::new();
            pipes.output.read_to_string(&mut output).unwrap();
            sender.send(output).unwrap();
        });
        writeln!(pipes.input, "{request}").unwrap();
        drop(pipes.input);
        // A regression must fail, not hang the suite indefinitely. On panic the
        // supervisor's Drop kills/reaps the controlled child and releases pipes.
        let response = receiver.recv_timeout(Duration::from_secs(5)).unwrap();
        assert_eq!(response, format!("reply:{request}"));
        reader.join().unwrap();
        supervisor.stop().unwrap();
        supervisor.stop().unwrap();
        assert_reaped(&pids);
    }
}

#[test]
fn spawn_failure_is_safe_and_does_not_reserve_the_supervisor() {
    let mut supervisor = Supervisor::new(ControlledLauncher {
        program: "/nonexistent-hagig-fixture/sensitive-name",
        ..ControlledLauncher::echo()
    });
    for _ in 0..2 {
        let error = supervisor.start().err().unwrap();
        assert_eq!(error, SupervisorError::Launch(LaunchError::SpawnFailed));
        assert_eq!(error.to_string(), "worker could not start");
    }
    supervisor.stop().unwrap();
}

#[test]
fn missing_private_pipe_rejects_and_reaps_a_live_child() {
    let launcher = ControlledLauncher {
        // Busy builtin loop stays alive even with null stdin until killed.
        script: "while :; do :; done",
        piped: false,
        ..ControlledLauncher::echo()
    };
    let pids = launcher.pids.clone();
    let mut supervisor = Supervisor::new(launcher);
    for _ in 0..2 {
        assert!(matches!(
            supervisor.start(),
            Err(SupervisorError::Launch(
                LaunchError::PrivatePipesUnavailable
            ))
        ));
        assert_reaped(&pids);
    }
}

#[test]
fn dropping_supervisor_terminates_live_worker_even_with_open_input() {
    let launcher = ControlledLauncher::echo();
    let pids = launcher.pids.clone();
    let mut supervisor = Supervisor::new(launcher);
    let mut pipes = supervisor.start().unwrap();
    // Positive control for the existence probe, while the worker awaits input.
    assert!(process_exists(pids.lock().unwrap()[0]));
    let (sender, receiver) = mpsc::channel();
    let reader = std::thread::spawn(move || {
        let mut output = Vec::new();
        pipes.output.read_to_end(&mut output).unwrap();
        sender.send(output).unwrap();
    });
    drop(supervisor);
    assert!(
        receiver
            .recv_timeout(Duration::from_secs(5))
            .unwrap()
            .is_empty()
    );
    drop(pipes.input);
    reader.join().unwrap();
    assert_reaped(&pids);
}

#[test]
fn production_launch_and_executable_fail_closed() {
    assert_eq!(NetworkIsolation::default(), NetworkIsolation::Required);
    assert_eq!(NetworkIsolation::Required.to_string(), "required");
    assert_eq!(NetworkIsolation::Disabled.to_string(), "disabled");
    assert_eq!(
        PlatformLauncher::unconfigured().network_isolation(),
        NetworkIsolation::Required
    );
    assert!(matches!(
        PlatformLauncher::unconfigured()
            .with_network_isolation(NetworkIsolation::Disabled)
            .launch(),
        Err(LaunchError::IsolationUnavailable)
    ));
    assert!(matches!(
        PlatformLauncher::unconfigured().launch(),
        Err(LaunchError::IsolationUnavailable)
    ));
    let output = Command::new(env!("CARGO_BIN_EXE_hagig"))
        .arg("--disable-sandbox")
        .env("HAGIG_DISABLE_SANDBOX", "1")
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(1));
    assert!(output.stdout.is_empty());
    assert_eq!(output.stderr, b"worker network isolation is unavailable\n");
}

#[test]
fn worker_executable_rejects_relative_paths() {
    assert!(matches!(
        WorkerExecutable::new("relative/sensitive-name"),
        Err(LaunchError::InvalidExecutable)
    ));
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
#[test]
fn configured_unimplemented_platform_still_refuses() {
    let worker = WorkerExecutable::new(std::env::current_exe().unwrap()).unwrap();
    assert!(matches!(
        PlatformLauncher::new(worker).launch(),
        Err(LaunchError::IsolationUnavailable)
    ));
}
