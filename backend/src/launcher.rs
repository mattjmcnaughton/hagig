//! Platform launch effects. Network blocking is required unless explicitly disabled.

use std::fmt;
use std::path::{Path, PathBuf};
use std::process::Child;

#[cfg(target_os = "linux")]
mod linux;

#[cfg(target_os = "macos")]
mod macos;

/// Fixed bootstrap acknowledgement, consumed before returning private stdout.
pub const WORKER_READY: &[u8] = b"HAGIG-WORKER-READY-v1\n";

#[cfg(any(target_os = "linux", target_os = "macos"))]
fn await_ready(child: &mut Child) -> std::io::Result<()> {
    use rustix::event::{PollFd, PollFlags, Timespec, poll};
    use rustix::io::Errno;
    use std::io::{self, Read};
    use std::time::{Duration, Instant};

    let output = child.stdout.as_mut().ok_or(io::ErrorKind::BrokenPipe)?;
    let deadline = Instant::now() + Duration::from_secs(5);
    // Read only the ACK, never consume bytes belonging to the worker protocol.
    let mut ack = [0; WORKER_READY.len()];
    let mut offset = 0;
    while offset < ack.len() {
        let remaining = deadline
            .checked_duration_since(Instant::now())
            .ok_or(io::ErrorKind::TimedOut)?;
        let timeout = Timespec::try_from(remaining).map_err(|_| io::ErrorKind::TimedOut)?;
        let mut descriptors = [PollFd::new(&*output, PollFlags::IN)];
        match poll(&mut descriptors, Some(&timeout)) {
            Err(Errno::INTR) => continue,
            Err(error) => return Err(error.into()),
            Ok(0) => return Err(io::ErrorKind::TimedOut.into()),
            Ok(_) => {}
        }
        match output.read(&mut ack[offset..]) {
            Ok(0) => return Err(io::ErrorKind::UnexpectedEof.into()),
            Ok(count) => offset += count,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error),
        }
        if ack[..offset] != WORKER_READY[..offset] {
            return Err(io::ErrorKind::InvalidData.into());
        }
    }
    Ok(())
}

/// Selected before worker startup, never inferred from an isolation failure.
/// Disabled is a supported explicit opt-out, not a claim of network blocking.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub enum NetworkIsolation {
    #[default]
    Required,
    Disabled,
}

impl fmt::Display for NetworkIsolation {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Required => "required",
            Self::Disabled => "disabled",
        })
    }
}

/// Content-free failures: never include OS errors, paths or worker diagnostics.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LaunchError {
    InvalidExecutable,
    IsolationUnavailable,
    SpawnFailed,
    WorkerNotReady,
    PrivatePipesUnavailable,
}

impl fmt::Display for LaunchError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::InvalidExecutable => "worker executable must be an absolute path",
            Self::IsolationUnavailable => "worker network isolation is unavailable",
            Self::SpawnFailed => "worker could not start",
            Self::WorkerNotReady => "worker readiness check failed",
            Self::PrivatePipesUnavailable => "worker private pipes are unavailable",
        })
    }
}

impl std::error::Error for LaunchError {}

/// Trusted, installed worker bootstrap, not a shell command or plugin.
///
/// The target takes no arguments and receives an empty environment. It must emit
/// exactly [`WORKER_READY`] and flush within five seconds of startup, then begin
/// the private worker protocol. No other stdout may precede the acknowledgement.
/// It must not load inference libraries/models until after acknowledgement; in
/// particular it must not link inference libraries with startup constructors.
/// This preserves the shared macOS bootstrap contract as well as Linux exec.
///
/// Resolve from the installed bundle, not PATH. Absolute paths are checked here;
/// executable existence/permissions are checked at launch. File/installer trust
/// remains the caller's responsibility. No arbitrary arguments or env overrides.
pub struct WorkerExecutable {
    path: PathBuf,
}

impl WorkerExecutable {
    pub fn new(path: impl Into<PathBuf>) -> Result<Self, LaunchError> {
        let path = path.into();
        if !path.is_absolute() {
            return Err(LaunchError::InvalidExecutable);
        }
        Ok(Self { path })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }
}

/// Constructor-injected platform boundary, not an inference-engine plugin API.
///
/// Required mode establishes OS-enforced external-network isolation BEFORE any
/// native/model loading and fails closed on setup errors, never retrying with
/// isolation disabled. Explicit disabled mode makes no network-blocking claim.
/// Both modes return a child with private piped stdin/stdout and suppressed stderr. They
/// must sanitize inherited descriptors and environment (including proxies),
/// never inherit connected sockets, and clean up any child on launch failure.
/// The worker must not spawn descendants that outlive its supervision.
///
/// A successful spawn alone does not prove isolation. Linux network-namespace
/// and macOS sandbox-exec adapters require separate platform evidence. Model
/// installation is outside this boundary. Test launchers belong only in tests.
pub trait SandboxedWorkerLauncher {
    fn launch(&self) -> Result<Child, LaunchError>;
}

/// OS-specific launch with required isolation by default, never automatic fallback.
/// Unconfigured launchers and platforms without an implemented hygiene adapter
/// refuse startup in either mode. TOML/server configuration is not implemented.
pub struct PlatformLauncher {
    worker: Option<WorkerExecutable>,
    network_isolation: NetworkIsolation,
}

impl PlatformLauncher {
    pub fn new(worker: WorkerExecutable) -> Self {
        Self {
            worker: Some(worker),
            network_isolation: NetworkIsolation::Required,
        }
    }

    pub fn with_network_isolation(mut self, mode: NetworkIsolation) -> Self {
        self.network_isolation = mode;
        self
    }

    /// Content-free selected policy; selection is not evidence of enforcement.
    pub fn network_isolation(&self) -> NetworkIsolation {
        self.network_isolation
    }

    pub fn unconfigured() -> Self {
        Self {
            worker: None,
            network_isolation: NetworkIsolation::Required,
        }
    }
}

impl SandboxedWorkerLauncher for PlatformLauncher {
    fn launch(&self) -> Result<Child, LaunchError> {
        let worker = self
            .worker
            .as_ref()
            .ok_or(LaunchError::IsolationUnavailable)?;
        #[cfg(target_os = "linux")]
        {
            linux::launch(worker, self.network_isolation)
        }
        #[cfg(target_os = "macos")]
        {
            macos::launch(worker, self.network_isolation)
        }
        #[cfg(not(any(target_os = "linux", target_os = "macos")))]
        {
            let _ = worker;
            Err(LaunchError::IsolationUnavailable)
        }
    }
}
