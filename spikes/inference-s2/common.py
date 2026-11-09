"""Shared harness for the S2 engine scripts. Synthetic fixtures only.

Each engine supplies `load()` and `transcribe(audio, vocabulary_or_None) -> str`.
The harness times cold load, one unrecorded warmup, then every fixture in plain
and vocabulary-biased modes, writing one JSON line per fixture/mode.
"""

import json
import os
import pathlib
import platform
import resource
import statistics
import struct
import sys
import time

import numpy as np

HERE = pathlib.Path(__file__).parent
OFFLINE_ENV = {
    "HF_HUB_OFFLINE": "1",
    "TRANSFORMERS_OFFLINE": "1",
    "HF_DATASETS_OFFLINE": "1",
    "HF_HUB_DISABLE_TELEMETRY": "1",
    "DO_NOT_TRACK": "1",
}


def go_offline():
    """Call before importing model libraries in run mode."""
    os.environ.update(OFFLINE_ENV)


def vocabulary():
    return [t for t in (HERE / "vocabulary.txt").read_text().splitlines() if t.strip()]


def corpus(fixtures):
    rows = []
    for line in (pathlib.Path(fixtures) / "corpus.tsv").read_text().splitlines():
        name, cls, reference, _ = line.split("\t")
        rows.append({"id": name, "class": cls, "reference": reference})
    return rows


def read_wav(path):
    """Mono 16 kHz PCM16 RIFF/WAVE -> float32 in [-1, 1]. Tolerates extra chunks."""
    data = pathlib.Path(path).read_bytes()
    if data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise ValueError(f"{path}: not RIFF/WAVE")
    pos, fmt, pcm = 12, None, None
    while pos + 8 <= len(data):
        cid, size = data[pos : pos + 4], struct.unpack("<I", data[pos + 4 : pos + 8])[0]
        body = data[pos + 8 : pos + 8 + size]
        if cid == b"fmt ":
            fmt = struct.unpack("<HHIIHH", body[:16])
        elif cid == b"data":
            pcm = body
        pos += 8 + size + (size & 1)
    tag, channels, rate, _, _, bits = fmt
    if tag not in (1, 0xFFFE) or channels != 1 or rate != 16000 or bits != 16:
        raise ValueError(f"{path}: expected mono 16 kHz PCM16, got {fmt}")
    return np.frombuffer(pcm[: len(pcm) // 2 * 2], dtype="<i2").astype(np.float32) / 32768.0


def peak_rss_bytes():
    rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return rss if platform.system() == "Darwin" else rss * 1024


def sha256(path):
    import hashlib

    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def verify(path, expected):
    actual = sha256(path)
    if actual != expected:
        raise SystemExit(f"{path}: sha256 {actual} != pinned {expected}")


def run_suite(engine, model, load, transcribe, fixtures, out, repeats, extra_meta=None):
    vocab = vocabulary()
    rows = corpus(fixtures)
    audio = {r["id"]: read_wav(pathlib.Path(fixtures) / f"{r['id']}.wav") for r in rows}

    started = time.perf_counter()
    load()
    load_seconds = time.perf_counter() - started
    transcribe(audio[rows[0]["id"]], None)  # warmup, not recorded

    with open(out, "w") as sink:
        for mode in ("plain", "biased"):
            for row in rows:
                texts, seconds = [], []
                for _ in range(repeats):
                    t0 = time.perf_counter()
                    texts.append(transcribe(audio[row["id"]], vocab if mode == "biased" else None))
                    seconds.append(time.perf_counter() - t0)
                record = {
                    "engine": engine,
                    "mode": mode,
                    **row,
                    "audio_seconds": round(len(audio[row["id"]]) / 16000, 3),
                    "text": texts[0],
                    "deterministic": len(set(texts)) == 1,
                    "seconds": [round(s, 4) for s in seconds],
                    "median_seconds": round(statistics.median(seconds), 4),
                }
                sink.write(json.dumps(record) + "\n")
                print(f"[{engine}] {mode:6} {row['id']:14} {record['median_seconds']:7.3f}s  {texts[0]!r}", file=sys.stderr)
        meta = {
            "engine": engine,
            "mode": "meta",
            "model": model,
            "load_seconds": round(load_seconds, 3),
            "peak_rss_mib": round(peak_rss_bytes() / 2**20, 1),
            "platform": platform.platform(),
            "machine": platform.machine(),
            "python": platform.python_version(),
            "repeats": repeats,
            **(extra_meta() if extra_meta else {}),
        }
        sink.write(json.dumps(meta) + "\n")
