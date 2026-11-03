//! Bounded safe WAV decoding for the inference spike, not a speech detector.
use std::{fs::File, io::Read, path::Path};

const MAX_FILE_BYTES: usize = 300 * 48_000 * 2 * 4 + 65_536;

#[derive(Debug, PartialEq)]
pub struct Audio {
    pub sample_rate: i32,
    pub samples: Vec<f32>,
}

pub fn read_wav(path: &Path) -> Result<Audio, &'static str> {
    let mut bytes = Vec::new();
    File::open(path)
        .and_then(|file| {
            file.take((MAX_FILE_BYTES + 1) as u64)
                .read_to_end(&mut bytes)
        })
        .map_err(|_| "audio_invalid")?;
    decode_wav(&bytes)
}

pub fn decode_wav(bytes: &[u8]) -> Result<Audio, &'static str> {
    let invalid = "audio_invalid";
    if bytes.len() < 12
        || bytes.len() > MAX_FILE_BYTES
        || &bytes[..4] != b"RIFF"
        || &bytes[8..12] != b"WAVE"
        || u32::from_le_bytes(bytes[4..8].try_into().unwrap()) as usize != bytes.len() - 8
    {
        return Err(invalid);
    }
    let mut format = None;
    let mut data = None;
    let mut offset = 12;
    while offset < bytes.len() {
        let header = bytes.get(offset..offset + 8).ok_or(invalid)?;
        let size = u32::from_le_bytes(header[4..8].try_into().unwrap()) as usize;
        let start = offset + 8;
        let end = start.checked_add(size).ok_or(invalid)?;
        let chunk = bytes.get(start..end).ok_or(invalid)?;
        match &header[..4] {
            b"fmt " => {
                if format.is_some()
                    || !(chunk.len() == 16 || (chunk.len() == 18 && chunk[16..18] == [0, 0]))
                {
                    return Err(invalid);
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
                    return Err(invalid);
                }
                format = Some((channels as usize, rate, bits as usize / 8, align as usize));
            }
            b"data" => {
                if format.is_none() || data.is_some() {
                    return Err(invalid);
                }
                data = Some(chunk);
            }
            _ => (),
        }
        offset = end.checked_add(size % 2).ok_or(invalid)?;
        if offset > bytes.len() {
            return Err(invalid);
        }
    }
    let (channels, rate, sample_bytes, align) = format.ok_or(invalid)?;
    let data = data.ok_or(invalid)?;
    let frames = data.len() / align;
    if data.is_empty()
        || data.len() % align != 0
        || frames > 300 * rate as usize
        || i32::try_from(frames).is_err()
    {
        return Err(invalid);
    }
    let mut samples = Vec::with_capacity(frames);
    for (index, sample) in data.chunks_exact(sample_bytes).enumerate() {
        let value = if sample_bytes == 2 {
            f32::from(i16::from_le_bytes(sample.try_into().unwrap())) / 32768.0
        } else {
            f32::from_le_bytes(sample.try_into().unwrap())
        };
        if !(-1.0..=1.0).contains(&value) {
            return Err(invalid);
        }
        // Match the pinned native spike's first-channel policy; no hidden mix.
        if index % channels == 0 {
            samples.push(value);
        }
    }
    Ok(Audio {
        sample_rate: rate as i32,
        samples,
    })
}

#[cfg(test)]
mod tests {
    use super::{decode_wav, MAX_FILE_BYTES};

    fn chunk(id: &[u8; 4], data: &[u8]) -> Vec<u8> {
        let mut bytes = id.to_vec();
        bytes.extend_from_slice(&(data.len() as u32).to_le_bytes());
        bytes.extend_from_slice(data);
        if !data.len().is_multiple_of(2) {
            bytes.push(0);
        }
        bytes
    }

    fn riff(chunks: &[Vec<u8>]) -> Vec<u8> {
        let mut bytes = b"RIFF\0\0\0\0WAVE".to_vec();
        for chunk in chunks {
            bytes.extend_from_slice(chunk);
        }
        let length = (bytes.len() - 8) as u32;
        bytes[4..8].copy_from_slice(&length.to_le_bytes());
        bytes
    }

    fn format(encoding: u16, channels: u16, rate: u32, bits: u16) -> Vec<u8> {
        let align = channels * (bits / 8);
        let mut bytes = Vec::new();
        bytes.extend_from_slice(&encoding.to_le_bytes());
        bytes.extend_from_slice(&channels.to_le_bytes());
        bytes.extend_from_slice(&rate.to_le_bytes());
        bytes.extend_from_slice(&(rate * u32::from(align)).to_le_bytes());
        bytes.extend_from_slice(&align.to_le_bytes());
        bytes.extend_from_slice(&bits.to_le_bytes());
        chunk(b"fmt ", &bytes)
    }

    #[test]
    fn supported_formats_preserve_rate_and_first_channel_samples() {
        for rate in [16_000, 44_100, 48_000] {
            for channels in [1, 2] {
                let mut pcm = Vec::new();
                let mut floats = Vec::new();
                for value in [i16::MIN, 0, i16::MAX] {
                    pcm.extend_from_slice(&value.to_le_bytes());
                    floats.extend_from_slice(&(f32::from(value) / 32768.0).to_le_bytes());
                    if channels == 2 {
                        pcm.extend_from_slice(&1234_i16.to_le_bytes());
                        floats.extend_from_slice(&0.75_f32.to_le_bytes());
                    }
                }
                for (encoding, bits, payload) in [(1, 16, &pcm), (3, 32, &floats)] {
                    let input = riff(&[
                        chunk(b"JUNK", &[7, 8, 9]),
                        format(encoding, channels, rate, bits),
                        chunk(b"data", payload),
                    ]);
                    let audio = decode_wav(&input).unwrap();
                    assert_eq!(audio.sample_rate, rate as i32);
                    assert_eq!(audio.samples, [-1.0, 0.0, 32767.0 / 32768.0]);
                }
            }
        }
    }

    #[test]
    fn malformed_frames_and_native_reader_regressions_are_rejected() {
        for (encoding, channels, bits, lengths) in [
            (1, 1, 32, vec![5, 6, 7]),
            (3, 1, 32, vec![5, 6, 7]),
            (1, 2, 16, vec![2, 6]),
            (3, 2, 32, vec![4, 12]),
            (1, 1, 16, vec![0, 1, 3]),
        ] {
            for length in lengths {
                assert_eq!(
                    decode_wav(&riff(&[
                        format(encoding, channels, 16_000, bits),
                        chunk(b"data", &vec![0; length]),
                    ])),
                    Err("audio_invalid")
                );
            }
        }
        for value in [f32::NAN, f32::INFINITY, -1.01, 1.01] {
            assert_eq!(
                decode_wav(&riff(&[
                    format(3, 2, 16_000, 32),
                    chunk(
                        b"data",
                        &[0.0_f32.to_le_bytes(), value.to_le_bytes()].concat()
                    ),
                ])),
                Err("audio_invalid")
            );
        }
    }

    #[test]
    fn container_lengths_headers_and_required_chunks_are_checked() {
        let fmt = format(1, 1, 16_000, 16);
        let data = chunk(b"data", &[0, 0]);
        let valid = riff(&[fmt.clone(), data.clone()]);
        assert!(decode_wav(&valid).is_ok());
        let mut extended = fmt[8..].to_vec();
        extended.extend_from_slice(&[0, 0]);
        assert!(decode_wav(&riff(&[chunk(b"fmt ", &extended), data.clone()])).is_ok());
        extended[16] = 1;
        assert_eq!(
            decode_wav(&riff(&[chunk(b"fmt ", &extended), data.clone()])),
            Err("audio_invalid")
        );
        for end in 0..valid.len() {
            assert_eq!(decode_wav(&valid[..end]), Err("audio_invalid"));
        }
        for chunks in [
            vec![fmt.clone()],
            vec![data.clone()],
            vec![data.clone(), fmt.clone()],
            vec![fmt.clone(), fmt.clone(), data.clone()],
            vec![fmt.clone(), data.clone(), data.clone()],
        ] {
            assert_eq!(decode_wav(&riff(&chunks)), Err("audio_invalid"));
        }
        for (offset, bytes) in [
            (4, u32::MAX.to_le_bytes()),
            (16, u32::MAX.to_le_bytes()),
            (28, 1_u32.to_le_bytes()),
            (32, 0_u32.to_le_bytes()),
            (40, u32::MAX.to_le_bytes()),
        ] {
            let mut damaged = valid.clone();
            damaged[offset..offset + 4].copy_from_slice(&bytes);
            assert_eq!(decode_wav(&damaged), Err("audio_invalid"));
        }
        let mut trailing = valid;
        trailing.push(0);
        assert_eq!(decode_wav(&trailing), Err("audio_invalid"));
    }

    #[test]
    fn unsupported_formats_and_duration_limits_fail_explicitly() {
        for (encoding, channels, rate, bits) in [
            (1, 1, 8000, 16),
            (1, 3, 16_000, 16),
            (1, 0, 16_000, 16),
            (1, 1, 16_000, 8),
            (1, 1, 16_000, 24),
            (1, 1, 16_000, 32),
            (3, 1, 16_000, 16),
            (0xfffe, 1, 16_000, 16),
        ] {
            assert_eq!(
                decode_wav(&riff(&[
                    format(encoding, channels, rate, bits),
                    chunk(b"data", &[0; 8])
                ])),
                Err("audio_invalid")
            );
        }
        let at_limit = vec![0; 300 * 16_000 * 2];
        assert_eq!(
            decode_wav(&riff(&[
                format(1, 1, 16_000, 16),
                chunk(b"data", &at_limit)
            ]))
            .unwrap()
            .samples
            .len(),
            300 * 16_000
        );
        let over = vec![0; at_limit.len() + 2];
        assert_eq!(
            decode_wav(&riff(&[format(1, 1, 16_000, 16), chunk(b"data", &over)])),
            Err("audio_invalid")
        );
        // Otherwise-valid oversized metadata distinguishes the file cap from
        // unrelated RIFF/header rejection (an oversized zero buffer would not).
        let mut oversized = riff(&[
            format(1, 1, 16_000, 16),
            chunk(b"data", &[0, 0]),
            chunk(b"JUNK", &[]),
        ]);
        let size_offset = oversized.len() - 4;
        oversized.resize(MAX_FILE_BYTES + 2, 0);
        let riff_length = (oversized.len() - 8) as u32;
        let metadata_length = (oversized.len() - size_offset - 4) as u32;
        oversized[4..8].copy_from_slice(&riff_length.to_le_bytes());
        oversized[size_offset..size_offset + 4].copy_from_slice(&metadata_length.to_le_bytes());
        assert_eq!(decode_wav(&oversized), Err("audio_invalid"));
    }
}
