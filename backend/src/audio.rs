//! Bounded safe RIFF/WAVE decoding. Never call the candidate's native WAV reader.
use std::fs::OpenOptions;
use std::io::Read;
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;

const MAX_FILE_BYTES: usize = 300 * 48_000 * 2 * 4 + 65_536;
const INVALID: &str = "invalid_audio";

pub fn read_wav(path: &Path) -> Result<Vec<f32>, &'static str> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(rustix::fs::OFlags::NONBLOCK.bits() as i32)
        .open(path)
        .map_err(|_| INVALID)?;
    if !file.metadata().map_err(|_| INVALID)?.is_file() {
        return Err(INVALID);
    }
    let mut bytes = Vec::new();
    file.take((MAX_FILE_BYTES + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|_| INVALID)?;
    decode_wav(&bytes)
}

/// PCM16 or finite normalized float32; mono/stereo; 16/44.1/48 kHz; <=300s.
/// Stereo is averaged, then linearly resampled at rational source positions.
/// Output duration rounds up by at most one 16k sample; endpoints are held.
/// This deliberately small converter is not an anti-aliasing/high-fidelity filter.
pub fn decode_wav(bytes: &[u8]) -> Result<Vec<f32>, &'static str> {
    if bytes.len() < 12
        || bytes.len() > MAX_FILE_BYTES
        || &bytes[..4] != b"RIFF"
        || &bytes[8..12] != b"WAVE"
        || u32::from_le_bytes(bytes[4..8].try_into().unwrap()) as usize != bytes.len() - 8
    {
        return Err(INVALID);
    }
    let mut format = None;
    let mut data = None;
    let mut offset = 12;
    while offset < bytes.len() {
        let header = bytes.get(offset..offset + 8).ok_or(INVALID)?;
        let size = u32::from_le_bytes(header[4..8].try_into().unwrap()) as usize;
        let start = offset + 8;
        let end = start.checked_add(size).ok_or(INVALID)?;
        let chunk = bytes.get(start..end).ok_or(INVALID)?;
        match &header[..4] {
            b"fmt " => {
                if format.is_some()
                    || !(chunk.len() == 16 || (chunk.len() == 18 && chunk[16..18] == [0, 0]))
                {
                    return Err(INVALID);
                }
                let encoding = u16::from_le_bytes(chunk[..2].try_into().unwrap());
                let channels = u16::from_le_bytes(chunk[2..4].try_into().unwrap());
                let rate = u32::from_le_bytes(chunk[4..8].try_into().unwrap());
                let byte_rate = u32::from_le_bytes(chunk[8..12].try_into().unwrap());
                let align = u16::from_le_bytes(chunk[12..14].try_into().unwrap());
                let bits = u16::from_le_bytes(chunk[14..16].try_into().unwrap());
                if !matches!((encoding, bits), (1, 16) | (3, 32))
                    || !matches!(channels, 1 | 2)
                    || !matches!(rate, 16_000 | 44_100 | 48_000)
                    || align != channels * (bits / 8)
                    || byte_rate != rate * u32::from(align)
                {
                    return Err(INVALID);
                }
                format = Some((
                    channels as usize,
                    rate as usize,
                    bits as usize / 8,
                    align as usize,
                ));
            }
            b"data" => {
                if format.is_none() || data.is_some() {
                    return Err(INVALID);
                }
                data = Some(chunk);
            }
            _ => (),
        }
        offset = end.checked_add(size % 2).ok_or(INVALID)?;
        if offset > bytes.len() {
            return Err(INVALID);
        }
    }
    let (channels, rate, sample_bytes, align) = format.ok_or(INVALID)?;
    let data = data.ok_or(INVALID)?;
    let frames = data.len() / align;
    if data.is_empty() || !data.len().is_multiple_of(align) || frames > 300 * rate {
        return Err(INVALID);
    }
    let mut mono = Vec::with_capacity(frames);
    for frame in data.chunks_exact(align) {
        let mut sum = 0.0;
        for sample in frame.chunks_exact(sample_bytes) {
            let value = if sample_bytes == 2 {
                f32::from(i16::from_le_bytes(sample.try_into().unwrap())) / 32768.0
            } else {
                f32::from_le_bytes(sample.try_into().unwrap())
            };
            if !(-1.0..=1.0).contains(&value) {
                return Err(INVALID);
            }
            sum += value;
        }
        mono.push(sum / channels as f32);
    }
    if rate == 16_000 {
        return Ok(mono);
    }
    Ok((0..(frames * 16_000).div_ceil(rate))
        .map(|i| {
            let position = i * rate;
            let index = position / 16_000;
            let fraction = (position % 16_000) as f64 / 16_000.0;
            let left = f64::from(mono[index]);
            let right = f64::from(mono[(index + 1).min(frames - 1)]);
            (left * (1.0 - fraction) + right * fraction) as f32
        })
        .collect())
}
