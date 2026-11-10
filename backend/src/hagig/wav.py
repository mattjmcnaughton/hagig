"""Bounded WAV decoding into canonical PCM (TDD section 9).

Accepts RIFF/WAVE with 16-bit integer or 32-bit float PCM (plain or
WAVE_FORMAT_EXTENSIBLE with the same subformats), mono or stereo, at 16, 44.1
or 48 kHz, up to five minutes. Produces mono 16 kHz float32 samples in
[-1, 1]: stereo is averaged, then resampled by deterministic linear
interpolation (no anti-aliasing filter). The input file is only read.

Errors carry a stable code and never the path, bytes or OS error text.
"""

import struct
from pathlib import Path

import numpy as np
from numpy.typing import NDArray

SAMPLE_RATE = 16_000
MAX_SECONDS = 300
SUPPORTED_RATES = frozenset({16_000, 44_100, 48_000})
# The largest supported data chunk (48 kHz stereo float32) plus room for
# headers and metadata chunks.
MAX_FILE_BYTES = MAX_SECONDS * 48_000 * 2 * 4 + 1024 * 1024

_PCM = 0x0001
_FLOAT = 0x0003
_EXTENSIBLE = 0xFFFE
_GUID_TAIL = b"\x00\x00\x00\x00\x10\x00\x80\x00\x00\xaa\x00\x38\x9b\x71"
_DTYPES = {(_PCM, 16): "<i2", (_FLOAT, 32): "<f4"}


class WavError(Exception):
    """A WAV input was rejected. `code` is stable and content-free."""

    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


def read_wav(path: Path) -> NDArray[np.float32]:
    """Read and decode a WAV file, reading at most MAX_FILE_BYTES + 1 bytes."""
    # Raise after the except block so the OS error (and its filename) is not
    # chained onto the WavError.
    try:
        with open(path, "rb") as handle:
            data = handle.read(MAX_FILE_BYTES + 1)
    except OSError:
        data = None
    if data is None:
        raise WavError("wav_unreadable")
    if len(data) > MAX_FILE_BYTES:
        raise WavError("wav_too_long")
    return decode_wav(data)


def decode_wav(data: bytes) -> NDArray[np.float32]:
    """Decode WAV bytes into canonical mono 16 kHz float32 PCM."""
    if len(data) < 12 or data[0:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise WavError("wav_malformed")
    (riff_size,) = struct.unpack_from("<I", data, 4)
    if riff_size + 8 != len(data):
        raise WavError("wav_malformed")

    fmt: tuple[str, int, int, int] | None = None
    samples: memoryview | None = None
    view = memoryview(data)
    pos = 12
    while pos < len(data):
        if pos + 8 > len(data):
            raise WavError("wav_malformed")
        chunk_id = data[pos : pos + 4]
        (size,) = struct.unpack_from("<I", data, pos + 4)
        start, end = pos + 8, pos + 8 + size
        if end > len(data):
            raise WavError("wav_malformed")
        if chunk_id == b"fmt ":
            if fmt is not None or samples is not None:
                raise WavError("wav_malformed")
            fmt = _parse_fmt(data[start:end])
        elif chunk_id == b"data":
            if fmt is None or samples is not None:
                raise WavError("wav_malformed")
            samples = view[start:end]
        # Chunks are word aligned; tolerate a missing pad after the last one.
        pos = end + (size & 1)
    if fmt is None or samples is None:
        raise WavError("wav_malformed")

    dtype, channels, rate, block_align = fmt
    if len(samples) == 0:
        raise WavError("wav_empty")
    if len(samples) % block_align:
        raise WavError("wav_malformed")
    if len(samples) // block_align > MAX_SECONDS * rate:
        raise WavError("wav_too_long")

    frames = np.frombuffer(samples, dtype=dtype).reshape(-1, channels)
    if dtype == "<i2":
        scaled = frames / 32768.0
    else:
        scaled = frames.astype(np.float64)
        if not np.all(np.isfinite(scaled)) or np.any(np.abs(scaled) > 1.0):
            raise WavError("wav_invalid_samples")
    mono = scaled.mean(axis=1)
    return _resample(mono, rate).astype(np.float32)


def _parse_fmt(body: bytes) -> tuple[str, int, int, int]:
    if len(body) < 16:
        raise WavError("wav_malformed")
    tag, channels, rate, byte_rate, block_align, bits = struct.unpack_from(
        "<HHIIHH", body
    )
    if tag == _EXTENSIBLE:
        if len(body) < 40:
            raise WavError("wav_malformed")
        extra_size, valid_bits, _channel_mask, sub_tag = struct.unpack_from(
            "<HHIH", body, 16
        )
        if extra_size < 22:
            raise WavError("wav_malformed")
        # SubFormat is the standard KSDATAFORMAT GUID carrying a 16-bit tag.
        if body[26:40] != _GUID_TAIL or valid_bits != bits:
            raise WavError("wav_unsupported")
        tag = sub_tag
    if channels == 0 or block_align != channels * bits // 8:
        raise WavError("wav_malformed")
    if byte_rate != rate * block_align:
        raise WavError("wav_malformed")
    dtype = _DTYPES.get((tag, bits))
    if dtype is None or channels > 2 or rate not in SUPPORTED_RATES:
        raise WavError("wav_unsupported")
    return dtype, channels, rate, block_align


def _resample(samples: NDArray[np.float64], rate: int) -> NDArray[np.float64]:
    if rate == SAMPLE_RATE:
        return samples
    # Output k sits at input position k * rate / SAMPLE_RATE, computed in exact
    # integer arithmetic. The last output never passes the last input sample.
    count = (len(samples) - 1) * SAMPLE_RATE // rate + 1
    position = np.arange(count, dtype=np.int64) * rate
    index = position // SAMPLE_RATE
    fraction = (position % SAMPLE_RATE) / SAMPLE_RATE
    following = np.minimum(index + 1, len(samples) - 1)
    return samples[index] + (samples[following] - samples[index]) * fraction
