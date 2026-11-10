"""Test-only worker: the real worker protocol with a scriptable fake engine.

Launched by the test server as `python -I fake_worker.py <control-dir>`. It is
never reachable through configuration, the CLI or the environment. Behavior is
read from `<control-dir>/control.json` (at startup for `tamper`, otherwise per
call), and the worker records what it saw into the control directory:

- `pids`: one line per launched worker.
- `launch-<pid>.json`: argv, environment keys, cwd and inherited descriptors.
- `load-<pid>.json`: the model directory and vocabulary from `load`.
- `audio-<pid>.bin`: the last PCM it was asked to transcribe.
- `computing-<pid>`: exists while a transcription is in progress.

Control keys: `text`, `text_repeat` ({unit, count}), `behavior` (`ok`,
`crash`, `stall`, `delay`), `delay` (seconds), `ignore_term` (bool), and
`tamper` (`stale_generation`, `wrong_generation`, `wrong_request_id`,
`stray_after_result`, `bad_ready`, `exit_before_ready`, `partial_ready`).
"""

import json
import os
import signal
import sys
import time
from pathlib import Path
from typing import BinaryIO, cast

CONTROL = Path(sys.argv[1])


def _inherited_fds() -> list[int]:
    fds = []
    for fd in range(3, 256):
        try:
            os.fstat(fd)
        except OSError:
            continue
        fds.append(fd)
    return fds


def _sandboxed() -> int | None:
    """Non-zero when macOS reports this process sandboxed; None elsewhere."""
    if sys.platform != "darwin":
        return None
    import ctypes

    check = ctypes.CDLL(None).sandbox_check
    check.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
    check.restype = ctypes.c_int
    return check(os.getpid(), None, 0)


# Before anything opens a file of its own.
_LAUNCH = {
    "argv": sys.argv,
    "env": sorted(os.environ),
    "env_values": dict(os.environ),
    "cwd": os.getcwd(),
    "fds": _inherited_fds(),
    "sandboxed": _sandboxed(),
}

from hagig.framing import HEADER, READY_LINE, message_frame  # noqa: E402
from hagig.worker import main, run  # noqa: E402

PID = os.getpid()


def control() -> dict:
    try:
        return json.loads((CONTROL / "control.json").read_text())
    except FileNotFoundError:
        return {}


def record(name: str, data: bytes) -> None:
    (CONTROL / name).write_bytes(data)


class FakeEngine:
    def load(self, model_dir: Path) -> None:
        record(
            f"load-{PID}.json",
            json.dumps({"model_dir": str(model_dir)}).encode(),
        )
        self.loaded = True

    def transcribe(self, audio, vocabulary) -> str:
        settings = control()
        record(f"audio-{PID}.bin", audio.tobytes())
        record(f"vocabulary-{PID}.json", json.dumps(list(vocabulary)).encode())
        if settings.get("ignore_term"):
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
        marker = CONTROL / f"computing-{PID}"
        marker.touch()
        behavior = settings.get("behavior", "ok")
        if behavior == "crash":
            os._exit(3)
        if behavior == "stall":
            while True:
                time.sleep(3600)
        if behavior == "delay":
            time.sleep(settings.get("delay", 0.5))
        marker.unlink()
        repeat = settings.get("text_repeat")
        if repeat:
            return repeat["unit"] * repeat["count"]
        return settings.get("text", "Fixture.")


ENGINES = {"qwen3-asr": FakeEngine, "mlx-whisper": FakeEngine}


class Tamper:
    """Rewrites the worker's outgoing frames to break the protocol on purpose."""

    def __init__(self, out, mode) -> None:
        self.out = out
        self.mode = mode
        self.pending = b""

    def write(self, data: bytes) -> int:
        if data == READY_LINE:
            bad = self.mode == "bad_ready"
            self.out.write(b"HAGIG-WORKER-READY-v2\n" if bad else data)
            return len(data)
        self.pending += data
        while len(self.pending) >= HEADER.size:
            _kind, length = HEADER.unpack(self.pending[: HEADER.size])
            end = HEADER.size + length
            if len(self.pending) < end:
                break
            payload, self.pending = self.pending[HEADER.size : end], self.pending[end:]
            message = json.loads(payload)
            extra = b""
            if message["type"] == "result":
                if self.mode == "stale_generation":
                    message["generation"] -= 1
                elif self.mode == "wrong_generation":
                    message["generation"] += 1
                elif self.mode == "wrong_request_id":
                    message["request_id"] = "someone-else"
                elif self.mode == "stray_after_result":
                    extra = b"x"
            self.out.write(message_frame(message) + extra)
        return len(data)

    def flush(self) -> None:
        self.out.flush()


def fake_main() -> None:
    with open(CONTROL / "pids", "a") as pids:
        pids.write(f"{PID}\n")
    record(f"launch-{PID}.json", json.dumps(_LAUNCH).encode())
    tamper = control().get("tamper")
    if tamper == "exit_before_ready":
        os._exit(0)
    if tamper == "partial_ready":
        os.write(1, READY_LINE[:9])
        os._exit(0)
    if not tamper:
        # The real entry point, with the fake engine table.
        main(ENGINES)
    stdout = os.fdopen(os.dup(1), "wb")
    os.dup2(2, 1)
    writer = cast("BinaryIO", Tamper(stdout, tamper))
    raise SystemExit(run(sys.stdin.buffer, writer, ENGINES))


fake_main()
