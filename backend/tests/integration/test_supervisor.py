"""Supervisor behavior that HTTP cannot time precisely, with the real fake worker."""

import asyncio
import importlib.util
import os
import signal
import struct
import sys

import pytest

from hagig.launcher import Launcher
from hagig.manifest import parse_manifest
from hagig.services.supervisor import Supervisor, WorkerError, WorkerSettings
from tests.support.harness import SUPPORT
from tests.support.models import FILES, synthetic_manifest, write_installation

AUDIO = struct.pack("<2f", 0.0, 0.5)


def test_the_real_worker_command_verifies_the_installation_at_load(tmp_path):
    """The production `python -I -m hagig.worker` and its real ENGINES table."""
    models = tmp_path / "models"
    manifest = parse_manifest(synthetic_manifest("qwen3-asr-0.6b"))
    version = write_installation(models, manifest, FILES, "v-" + "0" * 32)
    settings = WorkerSettings(
        launcher=Launcher(),
        mode="disabled",
        env={"PATH": "/usr/bin:/bin"},
        models_root=models,
        manifest=manifest,
        vocabulary=(),
    )

    async def attempt():
        sup = Supervisor(settings)
        try:
            await sup.transcribe("a", AUDIO)
        except WorkerError as error:
            return error.code
        finally:
            await sup.wait_reaped()

    # Valid files: the real worker loads past verification to the engine. The
    # portable environment has no engine stack (worker_failed); with the
    # qwen3-asr extra, the engine cannot load these synthetic files.
    engine = "model_invalid" if importlib.util.find_spec("torch") else "worker_failed"
    assert asyncio.run(attempt()) == engine
    weights = version / "model.safetensors"
    data = bytearray(weights.read_bytes())
    data[0] ^= 1
    weights.write_bytes(bytes(data))
    assert asyncio.run(attempt()) == "model_invalid"


def supervisor(tmp_path):
    control = tmp_path / "control"
    control.mkdir()
    models = tmp_path / "models"
    manifest = parse_manifest(synthetic_manifest("qwen3-asr-0.6b"))
    write_installation(models, manifest, FILES, "v-" + "0" * 32)
    command = (sys.executable, "-I", str(SUPPORT / "fake_worker.py"), str(control))
    settings = WorkerSettings(
        launcher=Launcher(command=command),
        mode="disabled",
        env={"PATH": "/usr/bin:/bin"},
        models_root=models,
        manifest=manifest,
        vocabulary=(),
    )
    return Supervisor(settings), control


def pids(control):
    return [int(p) for p in (control / "pids").read_text().split()]


async def until(predicate, timeout=5.0):
    end = asyncio.get_running_loop().time() + timeout
    while not predicate():
        assert asyncio.get_running_loop().time() < end, "condition not reached"
        await asyncio.sleep(0.01)


def test_cancel_while_taking_a_warm_worker_keeps_it_watched(tmp_path):
    sup, control = supervisor(tmp_path)

    async def scenario():
        assert await sup.transcribe("a", AUDIO) == "Fixture."
        warm = pids(control)[-1]
        # Cancel while transcribe waits for the cancelled idle watch.
        task = asyncio.create_task(sup.transcribe("b", AUDIO))
        await asyncio.sleep(0)
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
        assert sup.running and not sup.reaping
        # The worker dies while idle: the re-armed watch must retire it.
        os.kill(warm, signal.SIGKILL)
        await until(lambda: not sup.running)
        # The next request gets a fresh worker rather than failing.
        assert await sup.transcribe("c", AUDIO) == "Fixture."
        assert pids(control)[-1] != warm
        await sup.shutdown()

    asyncio.run(scenario())
