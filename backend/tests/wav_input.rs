use hagig::audio::decode_wav;

fn chunk(id: &[u8; 4], data: &[u8]) -> Vec<u8> {
    let mut bytes = id.to_vec();
    bytes.extend_from_slice(&(data.len() as u32).to_le_bytes());
    bytes.extend_from_slice(data);
    if !data.len().is_multiple_of(2) {
        bytes.push(0);
    }
    bytes
}

fn wav(encoding: u16, channels: u16, rate: u32, bits: u16, pcm: &[u8]) -> Vec<u8> {
    let align = channels * (bits / 8);
    let format = [
        encoding.to_le_bytes().to_vec(),
        channels.to_le_bytes().to_vec(),
        rate.to_le_bytes().to_vec(),
        (rate * u32::from(align)).to_le_bytes().to_vec(),
        align.to_le_bytes().to_vec(),
        bits.to_le_bytes().to_vec(),
    ]
    .concat();
    let mut bytes = b"RIFF\0\0\0\0WAVE".to_vec();
    bytes.extend(chunk(b"JUNK", &[1, 2, 3]));
    bytes.extend(chunk(b"fmt ", &format));
    bytes.extend(chunk(b"data", pcm));
    let length = (bytes.len() - 8) as u32;
    bytes[4..8].copy_from_slice(&length.to_le_bytes());
    bytes
}

#[test]
fn supported_pcm_is_downmixed_and_resampled_to_canonical_samples() {
    let pcm: Vec<_> = [-32768_i16, 0, 8192, 24576, 16384, -8192]
        .into_iter()
        .flat_map(i16::to_le_bytes)
        .collect();
    assert_eq!(
        decode_wav(&wav(1, 2, 16_000, 16, &pcm)).unwrap(),
        [-0.5, 0.5, 0.125]
    );
    let samples = [0.0_f32, 0.25, 0.5, -0.5, 1.0, -1.0, 0.0];
    let floats: Vec<_> = samples.into_iter().flat_map(f32::to_le_bytes).collect();
    let decoded = decode_wav(&wav(3, 1, 44_100, 32, &floats)).unwrap();
    // Output positions 0, 2.75625, 5.5125; not nearest-neighbor or 48k indices.
    assert_eq!(decoded.len(), 3);
    for (got, want) in decoded.iter().zip([0.0, -0.25625, -0.4875]) {
        assert!((got - want).abs() < 0.000001);
    }
    assert_eq!(
        decode_wav(&wav(3, 1, 48_000, 32, &floats)).unwrap(),
        [0.0, -0.5, 0.0]
    );
    assert_eq!(
        decode_wav(&wav(3, 1, 16_000, 32, &floats)).unwrap(),
        samples
    );
}

#[test]
fn malformed_containers_and_samples_never_reach_native_wav_code() {
    let valid = wav(1, 1, 16_000, 16, &[0, 0]);
    for end in 0..valid.len() {
        assert_eq!(decode_wav(&valid[..end]), Err("invalid_audio"));
    }
    for (encoding, channels, rate, bits, pcm) in [
        (1, 1, 16_000, 32, vec![0; 5]),
        (3, 1, 16_000, 32, vec![0; 5]),
        (1, 2, 16_000, 16, vec![0; 6]),
        (1, 1, 8000, 16, vec![0; 2]),
        (1, 1, 16_000, 24, vec![0; 3]),
        (1, 1, 16_000, 16, vec![]),
        (1, 3, 16_000, 16, vec![0; 6]),
    ] {
        assert_eq!(
            decode_wav(&wav(encoding, channels, rate, bits, &pcm)),
            Err("invalid_audio")
        );
    }
    for bad in [f32::NAN, f32::INFINITY, -1.001, 1.001] {
        // Validate the second channel too, even when the first is innocuous.
        assert_eq!(
            decode_wav(&wav(
                3,
                2,
                16_000,
                32,
                &[0.0_f32.to_le_bytes(), bad.to_le_bytes()].concat()
            )),
            Err("invalid_audio")
        );
    }
    let mut bad = valid.clone();
    bad[4..8].copy_from_slice(&u32::MAX.to_le_bytes());
    assert_eq!(decode_wav(&bad), Err("invalid_audio"));
    let mut trailing = valid;
    trailing.push(0);
    assert_eq!(decode_wav(&trailing), Err("invalid_audio"));
}

#[test]
fn five_minutes_is_inclusive_and_overlong_audio_is_not_truncated() {
    let mut pcm = vec![0; 300 * 16_000 * 2];
    assert_eq!(
        decode_wav(&wav(1, 1, 16_000, 16, &pcm)).unwrap().len(),
        4_800_000
    );
    pcm.extend([0, 0]);
    assert_eq!(
        decode_wav(&wav(1, 1, 16_000, 16, &pcm)),
        Err("invalid_audio")
    );
}
