"""Development measurements for AC8 and AC9 through the real stack (#49).

    python -m tests.inference.measure <data-dir> <out-dir> <model-id>...

Run from `backend/` on macOS with both engine extras and installed models.
Every clip goes through `hagig transcribe` to a server whose worker runs
under the real `seatbelt-v1.sb` (required mode), once with the corpus's
vocabulary configured (biased) and once without (plain); configuration is
read at server start, so each mode is a fresh server.

Fixtures are synthesized here, never committed: `corpus/corpus.tsv` and
`corpus/vocabulary.txt` are the S2 spike's (four short and one long
term-bearing clips, four short and one long controls, 3 s digital silence),
spoken by macOS `say` and converted by `afconvert`; plus 3 s of seeded white
noise and an empty WAV. Synthetic speech is not human dictation and the
vocabulary is not held out; the corpus is smaller than AC8's ten clips per
class. Hosted VM timings are not representative of a physical Mac.

Writes `<out>/measurements.jsonl` and `<out>/summary.md`.
"""

import json
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import wave
from pathlib import Path

import numpy as np

from tests.inference.stack import Stack, rss_mib

CORPUS = Path(__file__).resolve().parent / "corpus"
VOCABULARY = tuple(
    t for t in (CORPUS / "vocabulary.txt").read_text().splitlines() if t.strip()
)


def synthesize(out: Path) -> list[dict]:
    """Corpus rows plus noise and empty, each with its WAV under `out`."""
    out.mkdir(parents=True, exist_ok=True)
    rows = []
    for line in (CORPUS / "corpus.tsv").read_text().splitlines():
        name, kind, reference, spoken = line.split("\t")
        target = out / f"{name}.wav"
        if spoken:
            aiff = out / f"{name}.aiff"
            subprocess.run(
                ["/usr/bin/say", "-r", "175", "-o", str(aiff), spoken], check=True
            )
            subprocess.run(
                [
                    "/usr/bin/afconvert",
                    "-f",
                    "WAVE",
                    "-d",
                    "LEI16@16000",
                    "-c",
                    "1",
                    str(aiff),
                    str(target),
                ],
                check=True,
            )
            aiff.unlink()
        else:
            write_wav(target, np.zeros(16_000 * 3, dtype=np.int16))
        rows.append({"id": name, "class": kind, "reference": reference})
    rng = np.random.default_rng(49)
    noise = (rng.standard_normal(16_000 * 3) * 0.05 * 32767).astype(np.int16)
    write_wav(out / "noise.wav", noise)
    write_wav(out / "empty.wav", np.zeros(0, dtype=np.int16))
    rows.append({"id": "noise", "class": "noise", "reference": ""})
    rows.append({"id": "empty", "class": "empty", "reference": ""})
    return rows


def write_wav(path: Path, samples: np.ndarray) -> None:
    with wave.open(str(path), "wb") as out:
        out.setparams((1, 2, 16_000, 0, "NONE", "not compressed"))
        out.writeframes(samples.tobytes())


def duration(path: Path) -> float:
    with wave.open(str(path), "rb") as source:
        return round(source.getnframes() / source.getframerate(), 3)


def footprint_mib(pid: int) -> float | None:
    """macOS `footprint`: dirty memory including Metal (IOAccelerator)."""
    shown = subprocess.run(
        ["/usr/bin/footprint", "-p", str(pid), "-f", "bytes"],
        capture_output=True,
        text=True,
    ).stdout
    found = re.search(r"Footprint: (\d+) B", shown)
    return round(int(found.group(1)) / 2**20, 1) if found else None


class Sampler:
    """Samples one process's RSS every 100 ms while a request runs."""

    def __init__(self, stack: Stack) -> None:
        self.stack = stack
        self.peak = 0.0
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)

    def _run(self) -> None:
        while not self._stop.wait(0.1):
            for pid in self.stack.workers():
                self.peak = max(self.peak, rss_mib(pid) or 0.0)

    def __enter__(self) -> "Sampler":
        self._thread.start()
        return self

    def __exit__(self, *_: object) -> None:
        self._stop.set()
        self._thread.join()


def run_mode(stack: Stack, model_id: str, mode: str, rows: list[dict], wavs: Path):
    stack.configure(model_id, "required", VOCABULARY if mode == "biased" else ())
    records = []
    peak_rss, peak_footprint = 0.0, 0.0
    # The first request starts the server and worker, hashes and loads the model.
    first = rows[0]["id"]
    start = time.monotonic()
    cold = stack.cli("transcribe", str(wavs / f"{first}.wav"))
    cold_seconds = time.monotonic() - start
    for row in rows:
        path = wavs / f"{row['id']}.wav"
        with Sampler(stack) as sampler:
            start = time.monotonic()
            result = stack.cli("transcribe", str(path))
            seconds = time.monotonic() - start
        workers = stack.workers()
        footprint = footprint_mib(workers[0]) if workers else None
        peak_rss = max(peak_rss, sampler.peak)
        peak_footprint = max(peak_footprint, footprint or 0.0)
        records.append(
            {
                "engine": model_id,
                "mode": mode,
                **row,
                "audio_seconds": duration(path),
                "exit": result.returncode,
                "text": result.stdout.decode().rstrip("\n"),
                "stderr": result.stderr.decode().strip(),
                "seconds": round(seconds, 3),
            }
        )
        print(
            f"[{model_id}] {mode:6} {row['id']:14} {seconds:7.2f}s "
            f"{records[-1]['text'] or records[-1]['stderr']!r}",
            file=sys.stderr,
        )
    status = stack.status()
    records.append(
        {
            "engine": model_id,
            "mode": f"{mode}-meta",
            "network_isolation": status["network_isolation"],
            "cold_first_request_seconds": round(cold_seconds, 3),
            "cold_exit": cold.returncode,
            "warm_same_clip_seconds": next(
                r["seconds"] for r in records if r["id"] == first
            ),
            "peak_sampled_worker_rss_mib": peak_rss,
            "max_worker_footprint_mib": peak_footprint,
        }
    )
    stack.stop()
    return records


def words(text: str) -> list[str]:
    return re.sub(r"[^a-z0-9' ]+", " ", text.lower().replace("-", " ")).split()


def compact(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "", text.lower())


def wer(reference: str, hypothesis: str) -> float | None:
    ref, hyp = words(reference), words(hypothesis)
    if not ref:
        return None
    row = list(range(len(hyp) + 1))
    for i, word in enumerate(ref, 1):
        previous, row[0] = row[0], i
        for j, heard in enumerate(hyp, 1):
            previous, row[j] = (
                row[j],
                min(row[j] + 1, row[j - 1] + 1, previous + (word != heard)),
            )
    return row[-1] / len(ref)


def score(row: dict) -> float:
    """WER of a clip that has a reference."""
    value = wer(row["reference"], row["text"])
    assert value is not None
    return value


def terms(text: str) -> set[str]:
    return {t for t in VOCABULARY if compact(t) in compact(text)}


def summarize(records: list[dict], environment: str) -> str:
    out = ["# AC8/AC9 development measurements (hosted macOS VM)", "", environment, ""]
    out += [
        "## AC8: paired plain and biased",
        "",
        "| Engine | Mode | Terms recovered | Control WER (mean) | Overall WER (mean) "
        "| False term insertions (all clips) | Median s short / long |",
        "| --- | --- | ---: | ---: | ---: | ---: | --- |",
    ]
    clips = [
        r for r in records if r.get("class") in ("term", "control") and r["reference"]
    ]
    for engine in dict.fromkeys(r["engine"] for r in records):
        for mode in ("plain", "biased"):
            rows = [r for r in clips if r["engine"] == engine and r["mode"] == mode]
            if not rows:
                continue
            term_rows = [r for r in rows if r["class"] == "term"]
            expected = sum(len(terms(r["reference"])) for r in term_rows)
            hit = sum(len(terms(r["reference"]) & terms(r["text"])) for r in term_rows)
            # Insertions count every clip, including silence and noise.
            inserted = sum(
                len(terms(r["text"]) - terms(r["reference"]))
                for r in records
                if r["engine"] == engine and r["mode"] == mode
            )
            control = [score(r) for r in rows if r["class"] == "control"]
            overall = [score(r) for r in rows]
            short = [r["seconds"] for r in rows if not r["id"].startswith("long")]
            long = [r["seconds"] for r in rows if r["id"].startswith("long")]
            out.append(
                f"| {engine} | {mode} | {hit}/{expected} | "
                f"{statistics.mean(control):.3f} | {statistics.mean(overall):.3f} | "
                f"{inserted} | {statistics.median(short):.2f} / "
                f"{statistics.median(long):.2f} |"
            )
    out += [
        "",
        "## AC9: silence, noise and empty input",
        "",
        "| Engine | Mode | Clip | Exit | Output |",
        "| --- | --- | --- | ---: | --- |",
    ]
    for r in records:
        if r.get("id") in ("silence", "noise", "empty"):
            shown = repr(r["text"]) if r["exit"] == 0 else f"stderr {r['stderr']!r}"
            out.append(
                f"| {r['engine']} | {r['mode']} | {r['id']} | {r['exit']} | {shown} |"
            )
    out += [
        "",
        "## Latency, cold load and memory (not representative of a physical Mac)",
        "",
        "| Engine | Mode | Isolation | First request after server start (s) "
        "| Same clip warm (s) | Peak sampled worker RSS (MiB) "
        "| Max worker footprint (MiB) |",
        "| --- | --- | --- | ---: | ---: | ---: | ---: |",
    ]
    for r in records:
        if r["mode"].endswith("-meta"):
            out.append(
                f"| {r['engine']} | {r['mode'][:-5]} | {r['network_isolation']} | "
                f"{r['cold_first_request_seconds']} | {r['warm_same_clip_seconds']} | "
                f"{r['peak_sampled_worker_rss_mib']} | "
                f"{r['max_worker_footprint_mib']} |"
            )
    out += [
        "",
        "## Transcripts",
        "",
        "| Engine | Mode | Clip | s | WER | Reference | Text |",
        "| --- | --- | --- | ---: | ---: | --- | --- |",
    ]
    for r in records:
        if "class" in r:
            score = wer(r["reference"], r["text"]) if r["reference"] else None
            text = (r["text"] or f"({r['stderr'] or 'empty'})").replace("|", "\\|")
            out.append(
                f"| {r['engine']} | {r['mode']} | {r['id']} | {r['seconds']} | "
                f"{'' if score is None else f'{score:.3f}'} | "
                f"{r['reference']} | {text} |"
            )
    return "\n".join(out) + "\n"


def main() -> None:
    data, out, models = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3:]
    out.mkdir(parents=True, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix="hagig-measure-"))
    runtime = Path(tempfile.mkdtemp(prefix="hm", dir="/tmp"))
    runtime.chmod(0o700)
    try:
        rows = synthesize(root / "fixtures")
        records = []
        for model_id in models:
            for mode in ("plain", "biased"):
                stack_root = root / f"{model_id}-{mode}"
                stack_root.mkdir()
                stack = Stack(stack_root, runtime, data)
                try:
                    records += run_mode(stack, model_id, mode, rows, root / "fixtures")
                finally:
                    stack.cleanup()
        environment = subprocess.run(
            [
                "/bin/sh",
                "-c",
                "sw_vers; uname -m; sysctl -n machdep.cpu.brand_string "
                "hw.memsize hw.ncpu",
            ],
            capture_output=True,
            text=True,
        ).stdout.replace("\n", "; ")
        with open(out / "measurements.jsonl", "w") as sink:
            for r in records:
                sink.write(json.dumps(r, sort_keys=True) + "\n")
        (out / "summary.md").write_text(summarize(records, f"Host: {environment}"))
        print((out / "summary.md").read_text())
    finally:
        shutil.rmtree(root, ignore_errors=True)
        shutil.rmtree(runtime, ignore_errors=True)


if __name__ == "__main__":
    main()
