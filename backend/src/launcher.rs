//! Platform launch effects. No unrestricted production launch path exists.

use std::fmt;
use std::process::Child;

/// Content-free failures: never include OS errors, paths or worker diagnostics.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LaunchError {
    IsolationUnavailable,
    SpawnFailed,
    PrivatePipesUnavailable,
}

impl fmt::Display for LaunchError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::IsolationUnavailable => "worker network isolation is unavailable",
            Self::SpawnFailed => "isolated worker could not start",
            Self::PrivatePipesUnavailable => "worker private pipes are unavailable",
        })
    }
}

impl std::error::Error for LaunchError {}

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

/// Fail-closed placeholder on ALL platforms, including Linux and macOS.
/// No executable, flag or environment variable can select an unsandboxed child.
pub struct PlatformLauncher;

impl SandboxedWorkerLauncher for PlatformLauncher {
    fn launch(&self) -> Result<Child, LaunchError> {
        Err(LaunchError::IsolationUnavailable)
    }
}
