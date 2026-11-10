import hashlib
import os
import struct
import threading
import wave
from pathlib import Path

import numpy as np
import pytest

from hagig.wav import MAX_FILE_BYTES, WavError, decode_wav, read_wav

FIXTURE = Path(__file__).parents[1] / "fixtures" / "speech.wav"
PCM = 1
FLOAT = 3
EXTENSIBLE = 0xFFFE
GUID_TAIL = b"\x00\x00\x10\x00\x80\x00\x00\xaa\x00\x38\x9b\x71"


def fmt_chunk(tag, channels, rate, bits, *, block_align=None, byte_rate=None):
    block_align = channels * bits // 8 if block_align is None else block_align
    byte_rate = rate * block_align if byte_rate is None else byte_rate
    return chunk(
        b"fmt ",
        struct.pack("<HHIIHH", tag, channels, rate, byte_rate, block_align, bits),
    )


def extensible_fmt_chunk(
    sub_tag, channels, rate, bits, valid_bits, *, extra_size=22, guid_tail=GUID_TAIL
):
    block_align = channels * bits // 8
    body = (
        struct.pack(
            "<HHIIHHHHI",
            EXTENSIBLE,
            channels,
            rate,
            rate * block_align,
            block_align,
            bits,
            extra_size,
            valid_bits,
            0,
        )
        + struct.pack("<I", sub_tag)
        + guid_tail
    )
    return chunk(b"fmt ", body)


def chunk(chunk_id, body):
    return chunk_id + struct.pack("<I", len(body)) + body + b"\x00" * (len(body) % 2)


def riff(*chunks):
    body = b"WAVE" + b"".join(chunks)
    return b"RIFF" + struct.pack("<I", len(body)) + body


def pcm16(*samples):
    return struct.pack(f"<{len(samples)}h", *samples)


def f32(*samples):
    return struct.pack(f"<{len(samples)}f", *samples)


def wav(tag, channels, rate, bits, payload):
    return riff(fmt_chunk(tag, channels, rate, bits), chunk(b"data", payload))


def code_of(data):
    with pytest.raises(WavError) as error:
        decode_wav(data)
    return error.value.code


# Supported formats


def test_pcm16_mono_16k_scales_by_32768():
    out = decode_wav(wav(PCM, 1, 16000, 16, pcm16(0, 16384, -32768, 32767)))
    assert out.dtype == np.float32
    np.testing.assert_array_equal(out, [0.0, 0.5, -1.0, 32767 / 32768])


def test_float32_stereo_is_averaged():
    payload = f32(0.5, 0.25, -1.0, 1.0, 0.75, -0.25)
    out = decode_wav(wav(FLOAT, 2, 16000, 32, payload))
    np.testing.assert_allclose(out, [0.375, 0.0, 0.25], atol=1e-7)


def test_pcm16_stereo_is_averaged():
    out = decode_wav(wav(PCM, 2, 16000, 16, pcm16(16384, 0, -32768, -16384)))
    np.testing.assert_array_equal(out, [0.25, -0.75])


def test_float32_accepts_full_scale():
    out = decode_wav(wav(FLOAT, 1, 16000, 32, f32(-1.0, 1.0)))
    np.testing.assert_array_equal(out, [-1.0, 1.0])


def test_48k_resamples_by_taking_every_third_sample():
    payload = f32(0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7)
    out = decode_wav(wav(FLOAT, 1, 48000, 32, payload))
    np.testing.assert_allclose(out, [0.1, 0.4, 0.7], atol=1e-6)


def test_44k1_interpolates_linearly_without_extrapolating():
    # Output k sits at input position k * 44100 / 16000; the last output may
    # not pass the last input. Position 1 is 2.75625: x2 + 0.75625 * (x3 - x2).
    payload = f32(0.0, 0.1, -0.2, 0.6, 0.3)
    out = decode_wav(wav(FLOAT, 1, 44100, 32, payload))
    np.testing.assert_allclose(out, [0.0, -0.2 + 0.75625 * 0.8], atol=1e-6)


def test_resampled_length_never_extends_past_the_last_input():
    # 3 inputs at 44.1 kHz span 2 / 44100 s, which holds only output position 0.
    out = decode_wav(wav(FLOAT, 1, 44100, 32, f32(0.25, 0.5, 0.75)))
    np.testing.assert_array_equal(out, [0.25])


@pytest.mark.parametrize("rate", [16000, 44100, 48000])
def test_one_second_becomes_16000_samples(rate):
    out = decode_wav(wav(PCM, 1, rate, 16, b"\x00\x00" * rate))
    assert out.shape == (16000,)


def test_resampling_is_deterministic():
    rng = np.random.default_rng(7)
    payload = rng.uniform(-1, 1, 4410).astype("<f4").tobytes()
    data = wav(FLOAT, 2, 44100, 32, payload)
    assert decode_wav(data).tobytes() == decode_wav(data).tobytes()


def test_extensible_pcm16_and_float32_are_accepted():
    pcm = riff(
        extensible_fmt_chunk(PCM, 1, 16000, 16, 16), chunk(b"data", pcm16(16384))
    )
    flt = riff(extensible_fmt_chunk(FLOAT, 1, 16000, 32, 32), chunk(b"data", f32(-0.5)))
    np.testing.assert_array_equal(decode_wav(pcm), [0.5])
    np.testing.assert_array_equal(decode_wav(flt), [-0.5])


def test_unknown_chunks_are_skipped_including_odd_size_padding():
    data = riff(
        fmt_chunk(PCM, 1, 16000, 16),
        chunk(b"LIST", b"abc"),  # odd size, so a pad byte follows
        chunk(b"data", pcm16(16384, -16384)),
    )
    np.testing.assert_array_equal(decode_wav(data), [0.5, -0.5])


def test_real_fixture_matches_stdlib_wave_decoding():
    with wave.open(str(FIXTURE), "rb") as reference:
        assert (reference.getnchannels(), reference.getframerate()) == (1, 16000)
        frames = reference.readframes(reference.getnframes())
    expected = np.frombuffer(frames, dtype="<i2") / 32768.0
    out = read_wav(FIXTURE)
    assert out.shape == expected.shape
    np.testing.assert_array_equal(out, expected.astype(np.float32))


# Duration limit: five minutes of frames at the file's own rate


def test_exactly_five_minutes_at_48k_is_accepted():
    out = decode_wav(wav(PCM, 1, 48000, 16, bytes(2 * 300 * 48000)))
    assert out.shape == (300 * 16000,)


def test_one_frame_over_five_minutes_is_rejected():
    assert (
        code_of(wav(PCM, 1, 16000, 16, bytes(2 * (300 * 16000 + 1)))) == "wav_too_long"
    )


def test_stereo_limit_counts_frames_not_samples():
    # 300 s of stereo frames is twice as many samples as 300 s of mono.
    out = decode_wav(wav(PCM, 2, 16000, 16, bytes(4 * 300 * 16000)))
    assert out.shape == (300 * 16000,)


# Unsupported but well-formed input


@pytest.mark.parametrize(
    ("tag", "channels", "rate", "bits"),
    [
        (PCM, 1, 16000, 8),
        (PCM, 1, 16000, 24),
        (PCM, 1, 16000, 32),
        (FLOAT, 1, 16000, 64),
        (FLOAT, 1, 16000, 16),
        (PCM, 3, 16000, 16),
        (PCM, 1, 22050, 16),
        (PCM, 1, 8000, 16),
        (2, 1, 16000, 16),  # ADPCM
    ],
)
def test_unsupported_formats(tag, channels, rate, bits):
    frame = channels * bits // 8
    assert (
        code_of(wav(tag, channels, rate, bits, bytes(frame * 4))) == "wav_unsupported"
    )


@pytest.mark.parametrize(
    ("sub_tag", "bits", "valid_bits"),
    [(PCM, 32, 24), (PCM, 24, 24), (FLOAT, 64, 64), (2, 16, 16), (PCM, 16, 12)],
)
def test_unsupported_extensible_subformats(sub_tag, bits, valid_bits):
    data = riff(
        extensible_fmt_chunk(sub_tag, 1, 16000, bits, valid_bits),
        chunk(b"data", bytes(bits // 8 * 4)),
    )
    assert code_of(data) == "wav_unsupported"


def test_extensible_with_a_non_standard_subformat_guid_is_unsupported():
    for fmt in (
        extensible_fmt_chunk(PCM, 1, 16000, 16, 16, guid_tail=b"\xff" + GUID_TAIL[1:]),
        extensible_fmt_chunk(PCM | 0x10000, 1, 16000, 16, 16),  # GUID Data1 > 0xFFFF
    ):
        assert code_of(riff(fmt, chunk(b"data", pcm16(1)))) == "wav_unsupported"


def test_extensible_with_a_short_extension_is_malformed():
    fmt = extensible_fmt_chunk(PCM, 1, 16000, 16, 16, extra_size=0)
    assert code_of(riff(fmt, chunk(b"data", pcm16(1)))) == "wav_malformed"


@pytest.mark.parametrize(
    "samples", [(0.0, float("nan")), (float("inf"),), (0.5, 1.0000001), (-1.5,)]
)
def test_float_samples_must_be_finite_and_within_full_scale(samples):
    assert code_of(wav(FLOAT, 1, 16000, 32, f32(*samples))) == "wav_invalid_samples"


def test_empty_data_is_rejected():
    assert code_of(wav(PCM, 1, 16000, 16, b"")) == "wav_empty"


# Malformed input


def _malformed_cases():
    good_fmt = fmt_chunk(PCM, 1, 16000, 16)
    good_data = chunk(b"data", pcm16(1, 2))
    good = riff(good_fmt, good_data)
    return {
        "empty file": b"",
        "short header": b"RIFF\x04\x00\x00\x00WAV",
        "not riff": b"RIFX" + good[4:],
        "not wave": good[:8] + b"AVI " + good[12:],
        "riff size too large": good[:4] + struct.pack("<I", len(good)) + good[8:],
        "riff size too small": good[:4] + struct.pack("<I", len(good) - 10) + good[8:],
        "trailing bytes": good + b"\x00\x00",
        "no fmt": riff(good_data),
        "no data": riff(good_fmt),
        "data before fmt": riff(good_data, good_fmt),
        "duplicate fmt": riff(good_fmt, good_fmt, good_data),
        "duplicate data": riff(good_fmt, good_data, good_data),
        "short fmt": riff(chunk(b"fmt ", good_fmt[8:22]), good_data),
        "short extensible fmt": riff(
            chunk(b"fmt ", extensible_fmt_chunk(PCM, 1, 16000, 16, 16)[8:30]), good_data
        ),
        "chunk overruns file": riff(
            good_fmt, b"data" + struct.pack("<I", 100) + b"\0\0"
        ),
        "truncated chunk header": riff(good_fmt, good_data, b"LIS"),
        "block align mismatch": riff(
            fmt_chunk(PCM, 1, 16000, 16, block_align=4), good_data
        ),
        "byte rate mismatch": riff(
            fmt_chunk(PCM, 1, 16000, 16, byte_rate=16000), good_data
        ),
        "partial frame": riff(
            fmt_chunk(PCM, 2, 16000, 16), chunk(b"data", pcm16(1, 2, 3))
        ),
        "zero channels": riff(fmt_chunk(PCM, 0, 16000, 16), good_data),
    }


MALFORMED = _malformed_cases()


@pytest.mark.parametrize("data", MALFORMED.values(), ids=MALFORMED.keys())
def test_malformed_input(data):
    assert code_of(data) == "wav_malformed"


# File handling


def test_read_wav_never_modifies_the_input(tmp_path):
    good = tmp_path / "good.wav"
    bad = tmp_path / "bad.wav"
    good.write_bytes(wav(PCM, 2, 44100, 16, pcm16(*range(-500, 500))))
    bad.write_bytes(wav(PCM, 1, 22050, 16, pcm16(1, 2)))
    for path in (good, bad):
        path.chmod(0o400)
    before = {
        p: (hashlib.sha256(p.read_bytes()).hexdigest(), p.stat()) for p in (good, bad)
    }

    read_wav(good)
    with pytest.raises(WavError):
        read_wav(bad)

    for path, (digest, stat) in before.items():
        after = path.stat()
        assert hashlib.sha256(path.read_bytes()).hexdigest() == digest
        assert (after.st_mtime_ns, after.st_size, after.st_mode) == (
            stat.st_mtime_ns,
            stat.st_size,
            stat.st_mode,
        )


def test_read_wav_rejects_oversized_files(tmp_path):
    path = tmp_path / "huge.wav"
    with path.open("wb") as handle:
        handle.write(wav(PCM, 1, 16000, 16, pcm16(1)))
        handle.truncate(MAX_FILE_BYTES + 1)  # sparse
    with pytest.raises(WavError) as error:
        read_wav(path)
    assert error.value.code == "wav_too_long"


def test_read_wav_stops_reading_an_endless_stream(tmp_path):
    # A FIFO that delivers more than the cap and then stays open without EOF:
    # only a bounded read returns, and memory stays bounded either way.
    path = tmp_path / "endless.wav"
    os.mkfifo(path)
    done = threading.Event()

    def write_then_hold_open():
        block = bytes(1024 * 1024)
        with path.open("wb") as handle:
            try:
                for _ in range(MAX_FILE_BYTES // len(block) + 64):
                    handle.write(block)
                handle.flush()
            except BrokenPipeError:
                return
            done.wait()

    writer = threading.Thread(target=write_then_hold_open, daemon=True)
    writer.start()
    result = {}

    def read():
        try:
            read_wav(path)
        except WavError as error:
            result["code"] = error.code

    reader = threading.Thread(target=read, daemon=True)
    reader.start()
    reader.join(timeout=20)
    done.set()
    assert not reader.is_alive(), "read_wav did not stop at MAX_FILE_BYTES"
    assert result == {"code": "wav_too_long"}


@pytest.mark.parametrize("kind", ["missing", "directory"])
def test_unreadable_paths_report_a_code_without_the_path(tmp_path, kind):
    path = tmp_path / "SENTINEL-secret-name.wav"
    if kind == "directory":
        path.mkdir()
    with pytest.raises(WavError) as error:
        read_wav(path)
    assert error.value.code == "wav_unreadable"
    assert "SENTINEL" not in str(error.value)
    assert error.value.__cause__ is None
    assert error.value.__context__ is None
