//! Synthetic #6 tracer positive control, compiled only by observe_macos_runtime.py.
//! Not a worker or shipped executable. One loopback TCP connect, one loopback UDP
//! bind/send and one new file write; the outcomes are the file's only content.
use std::io::Write;
use std::net::{Ipv4Addr, TcpStream, UdpSocket};

fn outcome<T>(result: &std::io::Result<T>) -> String {
    match result {
        Ok(_) => "ok".into(),
        Err(error) => format!("os_error_{}", error.raw_os_error().unwrap_or(-1)),
    }
}

fn main() -> std::process::ExitCode {
    let port: u16 = env!("HG6_PORT").parse().expect("compile-time port");
    let tcp = TcpStream::connect((Ipv4Addr::LOCALHOST, port));
    let udp = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0));
    let send = match &udp {
        Ok(socket) => outcome(&socket.send_to(b"hg6", (Ipv4Addr::LOCALHOST, port))),
        Err(_) => "not_attempted".into(),
    };
    let name = std::env::current_exe()
        .ok()
        .and_then(|path| Some(path.file_name()?.to_string_lossy().into_owned()))
        .unwrap_or_else(|| "unknown".into());
    let path = std::path::Path::new(env!("HG6_WRITE_DIR")).join(format!("{name}.written"));
    let written = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .and_then(|mut file| {
            writeln!(
                file,
                "tcp_connect={} udp_bind={} udp_send={send}",
                outcome(&tcp),
                outcome(&udp)
            )?;
            Ok(file)
        });
    // Hold the descriptors so lsof/nettop samplers can see them.
    std::thread::sleep(std::time::Duration::from_millis(1500));
    drop((tcp, udp));
    if written.is_ok() {
        std::process::ExitCode::SUCCESS
    } else {
        std::process::ExitCode::FAILURE
    }
}
