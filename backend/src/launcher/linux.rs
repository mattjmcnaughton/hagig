//! Linux-only syscall boundary. No native inference code is loaded in the parent.

use std::ffi::CStr;
use std::io::{self, Read};
use std::mem::MaybeUninit;
use std::os::unix::process::CommandExt;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use rustix::event::{PollFd, PollFlags, Timespec, poll};
use rustix::fd::BorrowedFd;
use rustix::fs::{Mode, OFlags, RawDir, open};
use rustix::io::{Errno, FdFlags, fcntl_setfd, write};
use rustix::thread::{UnshareFlags, set_no_new_privs, unshare_unsafe};

use super::{LaunchError, NetworkIsolation, WORKER_READY, WorkerExecutable};

pub(super) fn launch(
    worker: &WorkerExecutable,
    mode: NetworkIsolation,
) -> Result<Child, LaunchError> {
    // Allocate/format BEFORE fork, not in the async-signal-safe child callback.
    let uid_map = format!("0 {} 1\n", rustix::process::getuid().as_raw());
    let gid_map = format!("0 {} 1\n", rustix::process::getgid().as_raw());
    let mut command = Command::new(worker.path());
    command
        .env_clear()
        .current_dir("/")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());

    // SAFETY: Only Linux syscalls, stack buffers and preallocated bytes are used
    // between fork and exec: no allocator, locks, std I/O, logging or panicking.
    // The child has one thread and a private descriptor table. CLOEXEC preserves
    // std's exec-error pipe until exec, so failed isolation cannot return Ok.
    #[allow(unsafe_code)]
    unsafe {
        command.pre_exec(move || {
            prepare(mode, uid_map.as_bytes(), gid_map.as_bytes())
                .map_err(|_| io::Error::from_raw_os_error(Errno::OPNOTSUPP.raw_os_error()))
        });
    }
    let mut child = command.spawn().map_err(|error| {
        if error.raw_os_error() == Some(Errno::OPNOTSUPP.raw_os_error()) {
            LaunchError::IsolationUnavailable
        } else {
            LaunchError::SpawnFailed
        }
    })?;
    if ready(&mut child).is_err() {
        let _ = child.kill();
        let _ = child.wait();
        return Err(LaunchError::WorkerNotReady);
    }
    Ok(child)
}

fn prepare(mode: NetworkIsolation, uid_map: &[u8], gid_map: &[u8]) -> rustix::io::Result<()> {
    if mode == NetworkIsolation::Required {
        // SAFETY: Only the post-fork, single-threaded child calls this; FILES is not
        // requested. The parent's namespace and descriptors cannot be changed.
        #[allow(unsafe_code)]
        unsafe {
            unshare_unsafe(UnshareFlags::NEWUSER | UnshareFlags::NEWNET)?
        };
        write_control(c"/proc/self/uid_map", uid_map)?;
        write_control(c"/proc/self/setgroups", b"deny")?;
        write_control(c"/proc/self/gid_map", gid_map)?;
    }
    set_no_new_privs(true)?;
    let directory = open(
        c"/proc/self/fd",
        OFlags::RDONLY | OFlags::DIRECTORY | OFlags::CLOEXEC,
        Mode::empty(),
    )?;
    let mut buffer = [MaybeUninit::uninit(); 4096];
    let mut entries = RawDir::new(directory, &mut buffer);
    while let Some(entry) = entries.next() {
        let entry = entry?;
        let fd = std::str::from_utf8(entry.file_name().to_bytes())
            .ok()
            .and_then(|name| name.parse::<i32>().ok());
        if let Some(fd) = fd.filter(|fd| *fd >= 3) {
            // SAFETY: This is an open fd enumerated by the single-threaded
            // child's /proc/self/fd. Nothing closes it during this borrow; only
            // its exec flag changes. This includes std's private error pipe.
            #[allow(unsafe_code)]
            fcntl_setfd(unsafe { BorrowedFd::borrow_raw(fd) }, FdFlags::CLOEXEC)?;
        }
    }
    Ok(())
}

fn write_control(path: &CStr, bytes: &[u8]) -> rustix::io::Result<()> {
    let file = open(path, OFlags::WRONLY | OFlags::CLOEXEC, Mode::empty())?;
    if write(&file, bytes)? != bytes.len() {
        return Err(Errno::IO);
    }
    Ok(())
}

fn ready(child: &mut Child) -> io::Result<()> {
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
