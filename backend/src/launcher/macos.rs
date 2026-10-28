//! Mac worker launch: deprecated Seatbelt in Required, explicit opt-out in Disabled.
//! No inference code is linked into this bootstrap.
//!
//! The target must emit READY before loading native inference/model assets. The
//! fixed Required policy is applied by sandbox-exec before target exec; READY
//! confirms target startup, not an independent runtime proof of policy behavior.
//! Disabled retains process/IPC hygiene but makes no OS-network-blocking claim.

use std::path::Path;
use std::process::{Child, Command, Stdio};

use super::{LaunchError, NetworkIsolation, WorkerExecutable, await_ready};

const POLICY: &str = include_str!("seatbelt-v1.sb");

pub(super) fn launch(
    worker: &WorkerExecutable,
    mode: NetworkIsolation,
) -> Result<Child, LaunchError> {
    launch_with(worker, mode, Path::new("/usr/bin/sandbox-exec"), POLICY)
}

// Private seam for malformed-policy/tool tests, never exposed as configuration.
fn launch_with(
    worker: &WorkerExecutable,
    mode: NetworkIsolation,
    sandbox: &Path,
    policy: &str,
) -> Result<Child, LaunchError> {
    let mut command = match mode {
        NetworkIsolation::Required => {
            let mut command = Command::new(sandbox);
            command.arg("-p").arg(policy).arg(worker.path());
            command
        }
        NetworkIsolation::Disabled => Command::new(worker.path()),
    };
    command
        .env_clear()
        .current_dir("/")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    bootstrap::configure_descriptor_hygiene(&mut command);
    let mut child = command.spawn().map_err(|_| LaunchError::SpawnFailed)?;
    if await_ready(&mut child).is_err() {
        // Keep diagnostics, target paths and partial ACK bytes out of errors.
        let _ = child.kill();
        let _ = child.wait();
        return Err(LaunchError::WorkerNotReady);
    }
    Ok(child)
}

// Only the postfork registration / descriptor enumeration needs unsafe. ACK
// polling, command configuration and supervision above/below inherit crate deny.
mod bootstrap {
    use rustix::io::{FdFlags, fcntl_setfd};
    use std::io;
    use std::os::fd::BorrowedFd;
    use std::os::unix::process::CommandExt;
    use std::process::Command;

    // Link the system library only. All signatures/types/constants come from
    // pinned libc; this empty block declares no handwritten foreign API.
    #[link(name = "proc")]
    #[allow(unsafe_code)]
    unsafe extern "C" {}

    pub(super) fn configure_descriptor_hygiene(command: &mut Command) {
        // SAFETY: postfork hook performs only syscall wrappers on stack data. It
        // neither allocates nor takes Rust locks. Marking, rather than closing,
        // preserves std's exec-error pipe until the sandbox tool is actually exec'd.
        #[allow(unsafe_code)]
        unsafe {
            command.pre_exec(sanitize_descriptors)
        };
    }

    fn sanitize_descriptors() -> io::Result<()> {
        // A full buffer is rejected, not treated as a complete enumeration. This
        // bounds postfork work without silently accepting unexamined descriptors.
        let mut entries = [libc::proc_fdinfo {
            proc_fd: -1,
            proc_fdtype: 0,
        }; 4096];
        let capacity = size_of_val(&entries);
        // SAFETY: valid stack buffer using libc's Darwin type/ABI, querying our
        // own child PID. libproc's wrapper invokes __proc_info without heap/locks.
        #[allow(unsafe_code)]
        let bytes = unsafe {
            libc::proc_pidinfo(
                rustix::process::getpid().as_raw_pid(),
                libc::PROC_PIDLISTFDS,
                0,
                entries.as_mut_ptr().cast(),
                capacity as i32,
            )
        };
        if bytes <= 0
            || bytes as usize >= capacity
            || !(bytes as usize).is_multiple_of(size_of::<libc::proc_fdinfo>())
        {
            return Err(io::Error::from_raw_os_error(libc::EIO));
        }
        for entry in &entries[..bytes as usize / size_of::<libc::proc_fdinfo>()] {
            // No other threads exist postfork, so the descriptor set cannot race.
            if entry.proc_fd >= 3 {
                // SAFETY: proc_pidinfo enumerated this live FD in the single-threaded
                // postfork child; nothing closes it until exec, beyond this borrow.
                #[allow(unsafe_code)]
                let fd = unsafe { BorrowedFd::borrow_raw(entry.proc_fd) };
                fcntl_setfd(fd, FdFlags::CLOEXEC).map_err(io::Error::from)?;
            }
        }
        Ok(())
    }
}

#[cfg(test)]
#[path = "macos_tests.rs"]
mod tests;
