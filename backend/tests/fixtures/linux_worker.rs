// Compiled with the pinned rustc by linux_isolation.rs, never a production bin.
// Deliberately uses only std; no inference libraries, model assets or credentials.
use std::io::{self, BufRead, Write};
use std::net::{SocketAddr, TcpStream};
use std::path::PathBuf;
use std::time::Duration;

fn connect(address: &str) -> String {
    match TcpStream::connect_timeout(
        &address.parse::<SocketAddr>().unwrap(),
        Duration::from_secs(1),
    ) {
        Ok(_) => "connected".into(),
        Err(error) => format!("errno:{}", error.raw_os_error().unwrap_or(-1)),
    }
}

fn main() {
    let boot_namespace = std::fs::read_link("/proc/self/ns/net").unwrap();
    let executable = PathBuf::from(std::env::args_os().next().unwrap());
    let mode = executable.file_stem().unwrap().to_str().unwrap();
    // PID-only observation files, within the test-owned fixture directory.
    std::fs::write(
        executable.with_extension("pid"),
        std::process::id().to_string(),
    )
    .unwrap();
    eprintln!("HAGIG_TEST_DIAGNOSTIC_CANARY");
    match mode {
        "bad-worker" => {
            println!("WRONG-BOOTSTRAP");
            io::stdout().flush().unwrap();
        }
        "suffix-worker" => {
            println!("HAGIG-WORKER-READY-v2");
            io::stdout().flush().unwrap();
        }
        "truncated-worker" => {
            print!("HAGIG-WORKER-");
            io::stdout().flush().unwrap();
            return;
        }
        "drip-worker" => {
            print!("HAGIG-");
            io::stdout().flush().unwrap();
            std::thread::sleep(Duration::from_secs(4));
            print!("WORKER");
            io::stdout().flush().unwrap();
        }
        "fragmented-worker" => {
            print!("HAGIG-WORKER-");
            io::stdout().flush().unwrap();
            std::thread::sleep(Duration::from_millis(100));
            println!("READY-v1\nboot_netns={}", boot_namespace.display());
            io::stdout().flush().unwrap();
        }
        "stall-worker" => {}
        "exit-worker" => return,
        _ => {
            // Protocol bytes follow in the same flush, before any input arrives;
            // a launcher that reads ahead and discards them must fail the test.
            println!(
                "HAGIG-WORKER-READY-v1\nboot_netns={}",
                boot_namespace.display()
            );
            io::stdout().flush().unwrap();
        }
    }
    if matches!(
        mode,
        "bad-worker" | "suffix-worker" | "drip-worker" | "stall-worker"
    ) {
        std::thread::sleep(Duration::from_secs(60));
        return;
    }
    let mut input = io::stdin().lock();
    let mut line = String::new();
    input.read_line(&mut line).unwrap();
    let fields: Vec<_> = line.split_whitespace().collect();
    let status = std::fs::read_to_string("/proc/self/status").unwrap();
    let nnp = status.lines().any(|line| line == "NoNewPrivs:\t1");
    println!("pid={}", std::process::id());
    println!(
        "netns={}",
        std::fs::read_link("/proc/self/ns/net").unwrap().display()
    );
    println!("ipv4={}", connect(fields[0]));
    println!("ipv6={}", connect(fields[1]));
    println!(
        "inherited_fd={}",
        std::fs::read_link(format!("/proc/self/fd/{}", fields[2])).is_ok()
    );
    println!("env_count={}", std::env::vars_os().count());
    println!(
        "cwd_root={}",
        std::env::current_dir().unwrap() == std::path::Path::new("/")
    );
    println!("no_new_privs={nnp}");
    println!("END");
    io::stdout().flush().unwrap();
    // Remain live for explicit kill/reap tests with the private input held open.
    line.clear();
    let _ = input.read_line(&mut line);
}
