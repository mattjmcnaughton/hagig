"""Both real engines through the real CLI, server and worker on macOS (#49).

Opt-in: see conftest.py. Transcriptions use `tests/fixtures/speech.wav`
(flite: "Open the project and run the tests"; both engines hear "project").
Networking is blocked for the worker by Seatbelt (required mode) or for the
whole stack by the test-only `block` profile, or available and observed through
mDNSResponder's per-process lookup log (see stack.py);
`test_isolation.py` shows that observer does see a lookup, so an empty list
here is a finding, not a blind spot. Each stack has a private, initially
empty HOME and TMPDIR, so cache writes there would be visible.
"""

import asyncio
import hashlib
import importlib
import json
import os
import signal
import sys
import time
import wave
from pathlib import Path

import pytest

from hagig.launcher import Launcher, worker_env
from hagig.manifest import load_manifest
from hagig.models import RECORD_NAME, ModelError, installed_model
from hagig.services.supervisor import Supervisor, WorkerSettings
from hagig.wav import read_wav
from tests.inference.stack import (
    SPEECH,
    TORCH_CACHE_DIR,
    dns_lookups,
    log_mark,
    processes,
    record,
    sandboxed,
    written,
)
from tests.support.harness import SUPPORT, wait_for

MODELS = ["qwen3-asr-0.6b", "whisper-large-v3-turbo"]


def transcribe(stack, wav=SPEECH, wrap=None):
    start = time.monotonic()
    result = stack.cli("transcribe", str(wav), wrap=wrap)
    return result, round(time.monotonic() - start, 2)


def heard(result) -> bool:
    return result.returncode == 0 and b"project" in result.stdout.lower()


@pytest.mark.parametrize("model_id", MODELS)
def test_cli_transcribes_with_the_worker_under_seatbelt(stack, model_id):
    stack.configure(model_id, "required")
    mark = log_mark()
    cold, cold_seconds = transcribe(stack)
    warm, warm_seconds = transcribe(stack)
    workers = stack.workers()
    status = stack.status()
    lookups = dns_lookups(mark)
    record(
        f"required-transcribe-{model_id}",
        {
            "text": cold.stdout.decode(),
            "stderr": cold.stderr.decode(),
            "cold_seconds": cold_seconds,
            "warm_seconds": warm_seconds,
            "worker_sandboxed": [sandboxed(pid) for pid in workers],
            "dns_lookups": lookups,
            "written": written(stack.home, stack.tmp),
        },
    )
    assert heard(cold) and cold.stderr == b""
    assert warm.stdout == cold.stdout
    assert status["network_isolation"] == "required"
    assert status["worker"] == "running"
    assert len(workers) == 1 and sandboxed(workers[0])
    assert lookups == []
    assert written(stack.home, stack.tmp) == []


@pytest.mark.parametrize("wrap", [None, "block"])
@pytest.mark.parametrize("model_id", MODELS)
def test_cli_transcribes_in_disabled_mode_without_networking(stack, model_id, wrap):
    """Disabled mode with networking available (observed: no lookups, no
    writes) and with it blocked for the whole stack (still transcribes)."""
    stack.configure(model_id, "disabled")
    mark = log_mark()
    result, seconds = transcribe(stack, wrap=wrap)
    workers = stack.workers()
    lookups = dns_lookups(mark)
    record(
        f"disabled-transcribe-{model_id}-{wrap}",
        {"text": result.stdout.decode(), "seconds": seconds, "dns_lookups": lookups},
    )
    assert heard(result)
    # Only the block profile sandboxes a disabled-mode worker.
    assert len(workers) == 1 and sandboxed(workers[0]) == (wrap == "block")
    assert lookups == []
    assert written(stack.home, stack.tmp) == []


@pytest.mark.parametrize("wrap", [None, "block"])
@pytest.mark.parametrize("model_id", MODELS)
def test_a_missing_model_fails_without_any_download(stack, tmp_path, model_id, wrap):
    """No installation: model_missing with networking available and blocked,
    no lookup, and nothing written to the data directory, HOME or TMPDIR.
    The server answers before launching any worker, so required mode's
    Seatbelt is not involved and the whole stack can be wrapped."""
    empty = tmp_path / "empty-data"
    empty.mkdir()
    stack.configure(model_id, "required", data=empty)
    mark = log_mark()
    result, _ = transcribe(stack, wrap=wrap)
    lookups = dns_lookups(mark)
    record(
        f"missing-{model_id}-{wrap}",
        {"stderr": result.stderr.decode(), "dns_lookups": lookups},
    )
    assert (result.returncode, result.stdout, result.stderr) == (
        1,
        b"",
        b"model_missing\n",
    )
    assert lookups == []
    assert written(empty, stack.home, stack.tmp) == []


def flip_byte(path):
    """Corrupt a file in place without changing its size."""
    with open(path, "r+b") as file:
        file.seek(path.stat().st_size // 2)
        byte = file.read(1)
        file.seek(-1, os.SEEK_CUR)
        file.write(bytes([byte[0] ^ 0xFF]))


def unloadable_whisper(home):
    """Whisper weights the engine cannot parse, with the install record updated
    to match, so they pass the server's and the worker's checks and reach the
    engine (converted files are pinned by the record, not the manifest)."""
    version = home / "hagig" / "models" / "whisper-large-v3-turbo" / "current"
    weights = version / "weights.safetensors"
    with open(weights, "r+b") as file:
        file.write(b"\xff" * 8)  # safetensors header length
    document = json.loads((version / RECORD_NAME).read_bytes())
    with open(weights, "rb") as file:
        digest = hashlib.file_digest(file, "sha256").hexdigest()
    for entry in document["files"]:
        if entry["path"] == "weights.safetensors":
            entry["sha256"] = digest
    (version / RECORD_NAME).write_text(json.dumps(document, indent=2) + "\n")


NETWORK = [("disabled", None), ("disabled", "block"), ("required", None)]


@pytest.mark.parametrize(("isolation", "wrap"), NETWORK)
@pytest.mark.parametrize("case", ["qwen-corrupt-weights", "whisper-unloadable-weights"])
def test_an_invalid_model_fails_without_any_download(stack, case, isolation, wrap):
    """A same-size corrupt Qwen file fails the worker's hash check; Whisper
    weights with a matching record fail inside the engine. Both are
    model_invalid with networking available, blocked for the whole stack,
    and blocked by Seatbelt for the worker, with no network attempt."""
    if case.startswith("qwen"):
        model_id = "qwen3-asr-0.6b"
        home = stack.clone(model_id)
        flip_byte(
            home / "hagig" / "models" / model_id / "current" / "model.safetensors"
        )
    else:
        model_id = "whisper-large-v3-turbo"
        home = stack.clone(model_id)
        unloadable_whisper(home)
    stack.configure(model_id, isolation, data=home)
    mark = log_mark()
    result, _ = transcribe(stack, wrap=wrap)
    lookups = dns_lookups(mark)
    record(
        f"invalid-{case}-{isolation}-{wrap}",
        {"stderr": result.stderr.decode(), "dns_lookups": lookups},
    )
    assert (result.returncode, result.stdout, result.stderr) == (
        1,
        b"",
        b"model_invalid\n",
    )
    assert lookups == []
    assert written(stack.home, stack.tmp) == []


@pytest.mark.parametrize("mode", ["required", "disabled"])
@pytest.mark.parametrize("model_id", MODELS)
def test_the_worker_reads_only_local_files_and_opens_no_sockets(
    stack, tmp_path, model_id, mode
):
    """The production worker and ENGINES under a Python audit hook (test-only
    `audited_worker.py`), loading the real installation and transcribing.
    Python-level only; native code is covered by Seatbelt and mDNSResponder."""
    data = Path(stack.env["XDG_DATA_HOME"])
    manifest = load_manifest(model_id)
    version = installed_model(data / "hagig" / "models", manifest)
    audit = tmp_path / "audit.json"
    settings = WorkerSettings(
        launcher=Launcher(
            command=(
                sys.executable,
                "-I",
                str(SUPPORT / "audited_worker.py"),
                str(audit),
            )
        ),
        mode=mode,
        env=worker_env(stack.env),
        models_root=data / "hagig" / "models",
        manifest=manifest,
        vocabulary=("Hagig", "Ghostty"),
    )
    audio = read_wav(SPEECH).astype("<f4").tobytes()

    async def run():
        supervisor = Supervisor(settings)
        try:
            return await supervisor.transcribe("audit", audio)
        finally:
            await supervisor.shutdown()

    text = asyncio.run(run())
    events = json.loads(audit.read_bytes())
    prefixes = (str(version.resolve()), sys.prefix, sys.base_prefix, "/dev/")
    elsewhere = sorted(
        p for p in events["reads"] if not os.path.realpath(p).startswith(prefixes)
    )
    model_reads = sorted(
        os.path.basename(p)
        for p in events["reads"]
        if os.path.realpath(p).startswith(str(version.resolve()))
    )
    record(
        f"audit-{model_id}-{mode}",
        {
            "text": text,
            "socket": events["socket"],
            "process": events["process"],
            "writes": events["writes"],
            "model_reads": model_reads,
            "reads_elsewhere": elsewhere,
        },
    )
    assert "project" in text.lower()
    assert events["socket"] == []
    assert events["process"] == []
    # Only PyTorch's import-time writes (see TORCH_CACHE_DIR): one
    # tempfile probe, created then removed, and the empty cache directory.
    removed = {path for event, path in events["writes"] if event == "os.remove"}
    assert [
        (event, path)
        for event, path in events["writes"]
        if path not in removed and Path(path).name != TORCH_CACHE_DIR
    ] == []
    assert written(stack.home, stack.tmp) == []
    # Nothing is read from a Hub, torch or tiktoken cache or the user's home.
    markers = ("/.cache/", "huggingface", "tiktoken", str(stack.home))
    assert [p for p in elsewhere if any(m in p for m in markers)] == []


@pytest.mark.parametrize("module", ["qwen3_asr", "mlx_whisper"])
@pytest.mark.parametrize("files", ["garbage", "absent"])
def test_engines_report_unloadable_files_as_model_invalid(tmp_path, module, files):
    model_dir = tmp_path / "model"
    if files == "garbage":
        model_dir.mkdir()
        for name in ("config.json", "model.safetensors", "weights.safetensors"):
            (model_dir / name).write_bytes(b"\xff" * 64)
    engine = importlib.import_module(f"hagig.engines.{module}").Engine()
    with pytest.raises(ModelError) as raised:
        engine.load(model_dir)
    assert raised.value.code == "model_invalid"
    # Raised outside the handler: no library error text is chained on.
    assert raised.value.__cause__ is None and raised.value.__context__ is None


def long_wav(path, seconds):
    with wave.open(str(SPEECH), "rb") as source:
        params, frames = source.getparams(), source.readframes(source.getnframes())
    with wave.open(str(path), "wb") as target:
        target.setparams(params)
        while target.getnframes() < seconds * params.framerate:
            target.writeframes(frames)


def test_killing_the_worker_mid_request_fails_it_and_a_fresh_worker_recovers(
    stack, tmp_path
):
    stack.configure("qwen3-asr-0.6b", "required")
    assert heard(stack.cli("transcribe", str(SPEECH)))
    [first] = stack.workers()
    audio = tmp_path / "long.wav"
    long_wav(audio, 40)
    running = stack.popen("transcribe", str(audio))
    wait_for(lambda: stack.status()["state"] == "busy", timeout=30)
    time.sleep(2)
    assert running.poll() is None, "the request finished before the kill"
    os.kill(first, signal.SIGKILL)
    stdout, stderr = running.communicate(timeout=60)
    wait_for(lambda: first not in {pid for pid, _, _ in processes()}, timeout=30)
    again = stack.cli("transcribe", str(SPEECH))
    workers = stack.workers()
    record(
        "worker-death",
        {
            "killed": (running.returncode, stdout.decode(), stderr.decode()),
            "next": (again.returncode, again.stdout.decode()),
            "new_worker": workers != [first],
        },
    )
    assert (running.returncode, stdout, stderr) == (1, b"", b"worker_failed\n")
    assert heard(again)
    assert len(workers) == 1 and workers != [first] and sandboxed(workers[0])
