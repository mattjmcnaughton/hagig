//! Platform launch effects. No unrestricted production launch path exists.

use std::fmt;
use std::path::{Path, PathBuf};
use std::process::Child;

#[cfg(target_os = "linux")]
mod linux;

/// Fixed bootstrap acknowledgement, consumed before returning private stdout.
pub const WORKER_READY: &[u8] = b"HAGIG-WORKER-READY-v1\n";

/// Content-free failures: never include OS errors, paths or worker diagnostics.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LaunchError {
    InvalidExecutable,
    IsolationUnavailable,
    SpawnFailed,
    PrivatePipesUnavailable,
}

impl fmt::Display for LaunchError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::InvalidExecutable => "worker executable must be an absolute path",
            Self::IsolationUnavailable => "worker network isolation is unavailable",
            Self::SpawnFailed => "isolated worker could not start",
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
/// Production implementations must establish OS-enforced external-network
/// isolation BEFORE any native/model loading, fail closed on setup errors, and
/// return a child with private piped stdin/stdout and suppressed stderr. They
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

/// OS-specific launch, never an unrestricted fallback. An unconfigured launcher
/// and platforms without an implemented isolation adapter always refuse startup.
pub struct PlatformLauncher {
    worker: Option<WorkerExecutable>,
}

impl PlatformLauncher {
    pub fn new(worker: WorkerExecutable) -> Self {
        Self {
            worker: Some(worker),
        }
    }

    pub fn unconfigured() -> Self {
        Self { worker: None }
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
            linux::launch(worker)
        }
        #[cfg(not(target_os = "linux"))]
        {
            // The independently owned macOS adapter is not integrated yet.
            let _ = worker;
            Err(LaunchError::IsolationUnavailable)
        }
    }
}
