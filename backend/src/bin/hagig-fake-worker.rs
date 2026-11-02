//! Explicit controlled lifecycle fixture, never a transcription implementation.
#![forbid(unsafe_code)]
use std::io::{Read, Write};
use std::time::Duration;

// Same bounded private v1 envelope as service: version, generation, ID, value.
fn reply(generation: u64, id: &str) -> Vec<u8> {
    let mut bytes = vec![1];
    bytes.extend_from_slice(&generation.to_be_bytes());
    bytes.push(id.len() as u8);
    bytes.extend_from_slice(id.as_bytes());
    bytes.push(1);
    bytes
}

fn main() {
    let mut output = std::io::stdout().lock();
    let mut input = std::io::stdin().lock();
    if output
        .write_all(hagig::launcher::WORKER_READY)
        .and_then(|_| output.flush())
        .is_err()
    {
        return;
    }
    loop {
        let mut header = [0; 10];
        if input.read_exact(&mut header).is_err() {
            return;
        }
        let len = header[9] as usize;
        if header[0] != 1 || !(1..=128).contains(&len) {
            return;
        }
        let mut body = [0; 129];
        if input.read_exact(&mut body[..len + 1]).is_err()
            || !body[..len]
                .iter()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_'))
        {
            return;
        }
        let id = std::str::from_utf8(&body[..len]).unwrap();
        let generation = u64::from_be_bytes(header[1..9].try_into().unwrap());
        let mut response = reply(generation, id);
        match body[len] {
            0 => std::thread::sleep(Duration::from_millis(200)),
            1 => std::process::exit(1),
            2 => {
                std::thread::sleep(Duration::from_secs(300));
                return;
            }
            3 => response = reply(generation.wrapping_sub(1), id),
            // Keep the length identical so rejection proves ID comparison,
            // rather than merely the response-size bound.
            4 => response[10] = if body[0] == b'x' { b'y' } else { b'x' },
            5 => response[9] = 255,
            6 => {
                let _ = output.write_all(&response[..1]);
                let _ = output.flush();
                std::thread::sleep(Duration::from_secs(300));
                return;
            }
            7 => response[0] = 2,
            8 => {
                eprintln!("HAGIG_SYNTHETIC_DIAGNOSTIC_CANARY");
                response = b"HAGIG_SYNTHETIC_DIAGNOSTIC_CANARY".to_vec();
            }
            9 => {
                if output
                    .write_all(&response[..1])
                    .and_then(|_| output.flush())
                    .is_err()
                {
                    return;
                }
                // Public test status observes the consumed prefix during this gap.
                std::thread::sleep(Duration::from_millis(500));
                response.drain(..1);
            }
            // Correct complete envelope and advertised length, plus a real byte.
            10 => response.push(0),
            _ => return,
        }
        if output
            .write_all(&response)
            .and_then(|_| output.flush())
            .is_err()
        {
            return;
        }
    }
}
