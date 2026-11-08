//! Private runtime validation and bounded client connection; no request state.
use super::SafeResult;
use std::fs;
use std::os::unix::fs::{DirBuilderExt, FileTypeExt, MetadataExt};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::time::Duration;

fn uid() -> u32 {
    rustix::process::getuid().as_raw()
}

pub(super) fn validate(path: &Path, mode: u32, kind: &str) -> SafeResult<()> {
    let m = fs::symlink_metadata(path).map_err(|_| "runtime_unavailable")?;
    if m.uid() != uid()
        || m.mode() & 0o7777 != mode
        || match kind {
            "directory" => !m.is_dir(),
            "socket" => !m.file_type().is_socket(),
            _ => !m.is_file() || m.nlink() != 1,
        }
    {
        return Err("unsafe_runtime");
    }
    Ok(())
}

pub(super) fn runtime(create: bool) -> SafeResult<PathBuf> {
    let base = match std::env::var_os("XDG_RUNTIME_DIR") {
        Some(value) => {
            let path = PathBuf::from(value);
            if !path.is_absolute() {
                return Err("unsafe_runtime");
            }
            validate(&path, 0o700, "directory")?;
            path
        }
        None => {
            #[cfg(target_os = "macos")]
            let path = {
                // Use exactly the inherited client root, not a Foundation or
                // libc-normalized temporary directory with a different spelling.
                let path = PathBuf::from(std::env::var_os("TMPDIR").ok_or("unsafe_runtime")?);
                if !path.is_absolute() {
                    return Err("unsafe_runtime");
                }
                validate(&path, 0o700, "directory")?;
                path
            };
            #[cfg(not(target_os = "macos"))]
            let path = {
                let path = PathBuf::from(format!("/tmp/hagig-{}", uid()));
                if create && !path.exists() {
                    match fs::DirBuilder::new().mode(0o700).create(&path) {
                        Ok(()) => (),
                        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => (),
                        Err(_) => return Err("runtime_unavailable"),
                    }
                }
                if path.exists() {
                    validate(&path, 0o700, "directory")?;
                }
                path
            };
            path
        }
    };
    let path = base.join("hagig");
    if create {
        match fs::DirBuilder::new().mode(0o700).create(&path) {
            Ok(()) => (),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => (),
            Err(_) => return Err("runtime_unavailable"),
        }
    }
    match fs::symlink_metadata(&path) {
        Ok(_) => validate(&path, 0o700, "directory")?,
        Err(e) if !create && e.kind() == std::io::ErrorKind::NotFound => (),
        Err(_) => return Err("runtime_unavailable"),
    }
    if path
        .join("server.sock")
        .as_os_str()
        .as_encoded_bytes()
        .len()
        > 100
    {
        return Err("runtime_path_too_long");
    }
    Ok(path)
}

pub(super) fn connect(path: &Path) -> SafeResult<Option<UnixStream>> {
    let socket = path.join("server.sock");
    match fs::symlink_metadata(&socket) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err("runtime_unavailable"),
        Ok(_) => validate(&socket, 0o600, "socket")?,
    }
    // Unix connect can block on a full listen backlog; bound the CLI operation,
    // including when an incompatible peer never accepts. No retries after timeout.
    let (sender, receiver) = mpsc::sync_channel(1);
    std::thread::spawn(move || {
        let _ = sender.send(UnixStream::connect(socket));
    });
    match receiver
        .recv_timeout(Duration::from_secs(5))
        .map_err(|_| "connection_timeout")?
    {
        Ok(stream) => {
            // Do not mutate socket timeouts between a terminal reply's header
            // and body: macOS can refuse setsockopt after the peer closes.
            // Client exchanges enforce one absolute deadline with nonblocking I/O.
            stream
                .set_nonblocking(true)
                .map_err(|_| "connection_failed")?;
            Ok(Some(stream))
        }
        Err(e) if e.kind() == std::io::ErrorKind::ConnectionRefused => Ok(None),
        Err(_) => Err("connection_failed"),
    }
}
