//! Explicit controlled lifecycle fixture, never a transcription implementation.
#![forbid(unsafe_code)]
use std::io::{Read, Write};
fn main() {
    let mut out = std::io::stdout().lock();
    out.write_all(hagig::launcher::WORKER_READY).unwrap();
    out.flush().unwrap();
    let mut action = [0];
    if std::io::stdin().read_exact(&mut action).is_err() {
        return;
    }
    match action[0] {
        0 => {
            std::thread::sleep(std::time::Duration::from_millis(200));
            let _ = out.write_all(&[1]);
            let _ = out.flush();
        }
        1 => std::process::exit(1),
        _ => std::thread::sleep(std::time::Duration::from_secs(300)),
    }
}
