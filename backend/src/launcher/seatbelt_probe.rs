// Compiled only by macOS tests with rustc, never a production worker/backend.
#![deny(unsafe_code)]

use std::io::{self, BufRead, Write};
use std::net::{SocketAddr, TcpStream};
use std::time::Duration;

// F_GETFD must accept closed raw numbers in this negative-control fixture;
// constructing a BorrowedFd for them would violate its validity requirement.
#[allow(unsafe_code)]
unsafe extern "C" {
    fn fcntl(fd: i32, command: i32, ...) -> i32;
}

fn main() {
    println!("HAGIG-WORKER-READY-v1");
    io::stdout().flush().unwrap();
    for line in io::stdin().lock().lines() {
        let line = line.unwrap();
        if let Some(address) = line.strip_prefix("connect ") {
            let address: SocketAddr = address.parse().unwrap();
            match TcpStream::connect_timeout(&address, Duration::from_millis(750)) {
                Ok(_) => println!("connected"),
                Err(error) => match error.raw_os_error() {
                    Some(1 | 13) => println!("permission-denied"),
                    _ => println!("unexpected-network-error"),
                },
            }
        } else if let Some(fd) = line.strip_prefix("fd ") {
            let fd: i32 = fd.parse().unwrap();
            // SAFETY: F_GETFD=1 only observes the supplied descriptor.
            #[allow(unsafe_code)]
            let result = unsafe { fcntl(fd, 1) };
            if result == -1 && io::Error::last_os_error().raw_os_error() == Some(9) {
                println!("closed"); // EBADF
            } else if result >= 0 {
                println!("inherited");
            } else {
                println!("unexpected-fd-error");
            }
        } else if line == "environment" {
            let contaminated = [
                "HAGIG_ISOLATION_SENTINEL",
                "HTTP_PROXY",
                "HTTPS_PROXY",
                "ALL_PROXY",
                "http_proxy",
                "https_proxy",
                "all_proxy",
                "DYLD_INSERT_LIBRARIES",
                "DYLD_LIBRARY_PATH",
            ]
            .iter()
            .any(|key| std::env::var_os(key).is_some());
            println!(
                "{}",
                if contaminated {
                    "contaminated"
                } else {
                    "clean"
                }
            );
        } else if line == "cwd" {
            println!(
                "{}",
                if std::env::current_dir().unwrap() == std::path::Path::new("/") {
                    "root"
                } else {
                    "other"
                }
            );
        } else if line == "exit" {
            break;
        } else {
            println!("unknown-command");
        }
        io::stdout().flush().unwrap();
    }
}
