//! Child ownership only: request state and protocol interpretation stay outside.

use std::fmt;
use std::process::{Child, ChildStdin, ChildStdout};

use crate::launcher::{LaunchError, SandboxedWorkerLauncher};

/// Private IPC endpoints transferred to the caller, never a public listener.
pub struct WorkerPipes {
    pub input: ChildStdin,
    pub output: ChildStdout,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SupervisorError {
    Launch(LaunchError),
    AlreadyRunning,
    StopFailed,
}

impl fmt::Display for SupervisorError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Launch(error) => error.fmt(f),
            Self::AlreadyRunning => f.write_str("worker is already owned by this supervisor"),
            Self::StopFailed => f.write_str("worker could not be stopped and reaped"),
        }
    }
}

impl std::error::Error for SupervisorError {}

/// Owns at most one child. No retry, request routing or cancellation state here.
pub struct Supervisor<L> {
    launcher: L,
    child: Option<Child>,
}

impl<L: SandboxedWorkerLauncher> Supervisor<L> {
    pub fn new(launcher: L) -> Self {
        Self {
            launcher,
            child: None,
        }
    }

    pub fn start(&mut self) -> Result<WorkerPipes, SupervisorError> {
        if self.child.is_some() {
            return Err(SupervisorError::AlreadyRunning);
        }
        let child = self.launcher.launch().map_err(SupervisorError::Launch)?;
        let child = self.child.insert(child);
        match (child.stdin.take(), child.stdout.take()) {
            (Some(input), Some(output)) => Ok(WorkerPipes { input, output }),
            _ => {
                self.stop()?;
                Err(SupervisorError::Launch(
                    LaunchError::PrivatePipesUnavailable,
                ))
            }
        }
    }
}

impl<L> Supervisor<L> {
    /// Immediate termination and reap; graceful protocol shutdown is future work.
    /// Retain ownership on error so a caller can retry, never launch a successor
    /// before the previous child is reaped. Idempotent once successfully stopped.
    pub fn stop(&mut self) -> Result<(), SupervisorError> {
        if let Some(child) = self.child.as_mut() {
            if child
                .try_wait()
                .map_err(|_| SupervisorError::StopFailed)?
                .is_none()
            {
                // Distinguish an exit race from a failed kill of a live child;
                // do not enter an unbounded wait after the latter.
                if child.kill().is_err()
                    && child
                        .try_wait()
                        .map_err(|_| SupervisorError::StopFailed)?
                        .is_none()
                {
                    return Err(SupervisorError::StopFailed);
                }
            }
            child.wait().map_err(|_| SupervisorError::StopFailed)?;
            self.child = None;
        }
        Ok(())
    }
}

impl<L> Drop for Supervisor<L> {
    fn drop(&mut self) {
        // Best effort during unwinding. Call stop explicitly to observe errors.
        let _ = self.stop();
    }
}
