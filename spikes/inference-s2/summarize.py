"""Summarize S2 result JSONL files as Markdown. Usage: summarize.py RESULT.jsonl..."""

import json
import pathlib
import re
import statistics
import sys

VOCAB = [t for t in (pathlib.Path(__file__).parent / "vocabulary.txt").read_text().splitlines() if t.strip()]


def words(text):
    return re.sub(r"[^a-z0-9' ]+", " ", text.lower().replace("-", " ")).split()


def compact(text):
    return re.sub(r"[^a-z0-9]+", "", text.lower())


def wer(ref, hyp):
    r, h = words(ref), words(hyp)
    if not r:
        return None
    row = list(range(len(h) + 1))
    for i, rw in enumerate(r, 1):
        prev, row[0] = row[0], i
        for j, hw in enumerate(h, 1):
            prev, row[j] = row[j], min(row[j] + 1, row[j - 1] + 1, prev + (rw != hw))
    return row[-1] / len(r)


def stat(fn, values):
    return f"{fn(values):.3f}" if values else "-"


def terms(text):
    return {t for t in VOCAB if compact(t) in compact(text)}


records, meta = [], {}
for path in sys.argv[1:]:
    for line in pathlib.Path(path).read_text().splitlines():
        rec = json.loads(line)
        if rec["mode"] == "meta":
            meta[rec["engine"]] = rec
        else:
            records.append(rec)

engines = list(dict.fromkeys(r["engine"] for r in records))
print("## Summary\n")
print("| Engine | Mode | Terms recovered | Control WER | Overall WER | False term insertions | Silence output | Median latency short / long (s) | Deterministic |")
print("| --- | --- | ---: | ---: | ---: | ---: | --- | --- | --- |")
for engine in engines:
    for mode in ("plain", "biased"):
        rows = [r for r in records if r["engine"] == engine and r["mode"] == mode]
        expected = sum(len(terms(r["reference"])) for r in rows if r["class"] == "term")
        hit = sum(len(terms(r["reference"]) & terms(r["text"])) for r in rows if r["class"] == "term")
        inserted = sum(len(terms(r["text"]) - terms(r["reference"])) for r in rows)
        control = [wer(r["reference"], r["text"]) for r in rows if r["class"] == "control" and r["reference"]]
        overall = [wer(r["reference"], r["text"]) for r in rows if r["reference"]]
        silence = next((r["text"] for r in rows if not r["reference"]), "")
        short = [r["median_seconds"] for r in rows if not r["id"].startswith("long")]
        long = [r["median_seconds"] for r in rows if r["id"].startswith("long")]
        print(
            f"| {engine} | {mode} | {hit}/{expected} | {stat(statistics.mean, control)} | {stat(statistics.mean, overall)} | "
            f"{inserted} | {silence!r} | {stat(statistics.median, short)} / {stat(statistics.median, long)} | "
            f"{all(r['deterministic'] for r in rows)} |"
        )

print("\n## Runs\n")
print("| Engine | Model | Device | Load (s) | Peak RSS (MiB) | Platform | Versions |")
print("| --- | --- | --- | ---: | ---: | --- | --- |")
skip = {"engine", "mode", "model", "device", "load_seconds", "peak_rss_mib", "platform", "machine", "python", "repeats"}
for engine, m in meta.items():
    versions = ", ".join(f"{k} {v}" for k, v in m.items() if k not in skip)
    print(f"| {engine} | `{m['model']}` | {m.get('device')} | {m['load_seconds']} | {m['peak_rss_mib']} | {m['platform']} | {versions} |")

print("\n## Transcripts\n")
for fixture in dict.fromkeys(r["id"] for r in records):
    ref = next(r for r in records if r["id"] == fixture)
    print(f"### {fixture} ({ref['audio_seconds']} s)\n\nReference: {ref['reference'] or '(silence)'}\n")
    print("| Engine | Mode | WER | Median s | Text |")
    print("| --- | --- | ---: | ---: | --- |")
    for r in records:
        if r["id"] == fixture:
            score = wer(r["reference"], r["text"])
            text = r["text"].replace("|", "\\|") or "(empty)"
            print(f"| {r['engine']} | {r['mode']} | {'' if score is None else f'{score:.3f}'} | {r['median_seconds']} | {text} |")
    print()
