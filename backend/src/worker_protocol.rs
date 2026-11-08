//! Private serial inference protocol, not a client API or configurable plugin.
use serde::{Deserialize, Serialize};
use std::io::{Read, Write};
use std::path::PathBuf;

// Allow the generation/error envelope overhead without narrowing the public
// 65,536-byte serialized result contract. The server enforces that public cap.
pub const CONTROL: usize = 65_536 + 256;
pub const AUDIO: usize = 19_200_000;

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
    pub version: u8,
    pub generation: u64,
    pub request_id: String,
    pub model: PathBuf,
    pub hotwords: String,
    pub audio_bytes: usize,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Reply {
    pub version: u8,
    pub generation: u64,
    pub request_id: String,
    pub text: Option<String>,
    pub code: Option<String>,
}

pub fn valid_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 128
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_'))
}

pub fn encode(value: &impl Serialize) -> Result<Vec<u8>, &'static str> {
    let bytes = serde_json::to_vec(value).map_err(|_| "worker_failed")?;
    if bytes.len() > CONTROL {
        return Err("result_too_large");
    }
    let mut frame = vec![1];
    frame.extend_from_slice(&(bytes.len() as u32).to_be_bytes());
    frame.extend(bytes);
    Ok(frame)
}

/// Blocking reads are confined to the supervised worker; the server uses its
/// nonblocking pipes and absolute cancellation/computation budget instead.
pub fn read_request(input: &mut impl Read) -> Result<(Request, Vec<f32>), &'static str> {
    let mut header = [0; 5];
    input.read_exact(&mut header).map_err(|_| "worker_failed")?;
    let size = u32::from_be_bytes(header[1..].try_into().unwrap()) as usize;
    if header[0] != 1 || size > CONTROL {
        return Err("worker_failed");
    }
    let mut bytes = vec![0; size];
    input.read_exact(&mut bytes).map_err(|_| "worker_failed")?;
    let request: Request = serde_json::from_slice(&bytes).map_err(|_| "worker_failed")?;
    if request.version != 1
        || !valid_id(&request.request_id)
        || !request.model.is_absolute()
        || request.audio_bytes == 0
        || request.audio_bytes > AUDIO
        || !request.audio_bytes.is_multiple_of(4)
    {
        return Err("worker_failed");
    }
    let mut pcm = vec![0; request.audio_bytes];
    input.read_exact(&mut pcm).map_err(|_| "worker_failed")?;
    let samples: Vec<_> = pcm
        .chunks_exact(4)
        .map(|b| f32::from_le_bytes(b.try_into().unwrap()))
        .collect();
    if samples.iter().any(|s| !(-1.0..=1.0).contains(s)) {
        return Err("worker_failed");
    }
    Ok((request, samples))
}

pub fn write_reply(output: &mut impl Write, reply: &Reply) -> Result<(), &'static str> {
    let frame = encode(reply)?;
    output
        .write_all(&frame)
        .and_then(|_| output.flush())
        .map_err(|_| "worker_failed")
}
