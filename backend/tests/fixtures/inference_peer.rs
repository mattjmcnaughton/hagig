//! Test-only std peer, compiled into a disposable sibling native-worker path.
//! It does not load models or exercise real inference/adoption.
#![forbid(unsafe_code)]
use std::io::{Read, Write};
use std::time::Duration;

fn main() {
    let mut input = std::io::stdin().lock();
    let mut output = std::io::stdout().lock();
    loop {
        let mut header = [0; 5];
        if input.read_exact(&mut header).is_err() {
            return;
        }
        assert_eq!(header[0], 1);
        let size = u32::from_be_bytes(header[1..].try_into().unwrap()) as usize;
        assert!(size <= 65_536);
        let mut bytes = vec![0; size];
        input.read_exact(&mut bytes).unwrap();
        let request = String::from_utf8(bytes).unwrap();
        // Only reads the trusted server's compact serialization, not user JSON.
        let number = |key: &str| -> usize {
            request
                .split_once(&format!("\"{key}\":"))
                .unwrap()
                .1
                .chars()
                .take_while(char::is_ascii_digit)
                .collect::<String>()
                .parse()
                .unwrap()
        };
        let generation = number("generation");
        let id = request
            .split_once("\"request_id\":\"")
            .unwrap()
            .1
            .split('"')
            .next()
            .unwrap();
        let size = number("audio_bytes");
        assert!((1..=19_200_000).contains(&size));
        let mut pcm = vec![0; size];
        input.read_exact(&mut pcm).unwrap();
        if id == "crash" {
            return;
        }
        if id == "stall" {
            let _ = input.read(&mut [0; 1]);
            return;
        }
        if matches!(id, "model_invalid" | "model_missing" | "result_too_large") {
            let bytes = format!("{{\"version\":1,\"generation\":{generation},\"request_id\":\"{id}\",\"text\":null,\"code\":\"{id}\"}}").into_bytes();
            output
                .write_all(&[&[1][..], &(bytes.len() as u32).to_be_bytes(), &bytes].concat())
                .unwrap();
            output.flush().unwrap();
            return;
        }
        let response_id = if id == "wrong" { "other" } else { id };
        let prefix = format!(
            "{{\"version\":1,\"generation\":{generation},\"request_id\":\"{response_id}\",\"text\":\""
        );
        let suffix = "\",\"code\":null}";
        let public_empty =
            format!("{{\"version\":1,\"type\":\"result\",\"request_id\":\"{id}\",\"text\":\"\"}}");
        let text = match id {
            "excess" => "x".repeat(8192 - 5 - prefix.len() - suffix.len()),
            "max" => "x".repeat(65_536 - public_empty.len()),
            "oversize" => "x".repeat(65_537 - public_empty.len()),
            _ => "Fixture".into(),
        };
        let bytes = format!("{prefix}{text}{suffix}").into_bytes();
        let mut frame = vec![1];
        frame.extend_from_slice(&(bytes.len() as u32).to_be_bytes());
        frame.extend(bytes);
        if id == "excess" {
            frame.push(0xff);
        }
        if id == "fragmented" {
            output.write_all(&frame[..1]).unwrap();
            output.flush().unwrap();
            std::thread::sleep(Duration::from_millis(250));
            output.write_all(&frame[1..]).unwrap();
        } else {
            output.write_all(&frame).unwrap();
        }
        output.flush().unwrap();
    }
}
