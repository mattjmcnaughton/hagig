"""Inference worker (TDD sections 2 and 6; backend/PROTOCOL.md).

Run by the server as `python -I -m hagig.worker` over stdin/stdout pipes. It
writes the ready line before importing any engine, loads the one engine the
`load` message names through a fixed table, then answers `transcribe`
requests. Stdout carries protocol frames only; nothing is logged.
"""

import importlib
import os
import sys
from collections.abc import Callable, Mapping, Sequence
from pathlib import Path
from typing import TYPE_CHECKING, Any, BinaryIO, Protocol

from hagig.framing import (
    HEADER,
    KIND_JSON,
    KIND_PCM,
    LOAD_CODES,
    OFFLINE_ENV,
    PROTOCOL_VERSION,
    READY_LINE,
    ProtocolError,
    decode_message,
    message_frame,
    parse_header,
)
from hagig.models import ModelError, verify_installation

if TYPE_CHECKING:
    import numpy as np
    from numpy.typing import NDArray


class Engine(Protocol):
    """One in-tree inference engine (TDD section 2)."""

    def load(self, model_dir: Path) -> None:
        """Load the model from a local directory, or raise EngineError."""
        ...

    def transcribe(
        self, audio: "NDArray[np.float32]", vocabulary: Sequence[str]
    ) -> str:
        """Transcribe mono 16 kHz float32 PCM, biased towards the vocabulary."""
        ...


class EngineError(Exception):
    """An engine failure with a stable code (`model_missing`, `model_invalid`)."""

    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


# The closed set of engines; only the selected one is ever imported. The
# modules arrive with #49, so selecting one before then fails the load.
ENGINES: Mapping[str, Callable[[], Engine]] = {
    "qwen3-asr": lambda: importlib.import_module("hagig.engines.qwen3_asr").Engine(),
    "mlx-whisper": lambda: importlib.import_module(
        "hagig.engines.mlx_whisper"
    ).Engine(),
}


class _Pipe:
    def __init__(self, stdin: BinaryIO, stdout: BinaryIO) -> None:
        self._in = stdin
        self._out = stdout

    def read_frame(self, allowed: frozenset[int]) -> tuple[int, bytes] | None:
        """The next frame, or None on EOF at a frame boundary (the exit request).

        Buffered binary reads block until `size` bytes or EOF, so a short read
        means EOF. `length` comes from a validated header.
        """
        header = self._in.read(HEADER.size)
        if not header:
            return None
        if len(header) != HEADER.size:
            raise ProtocolError()
        kind, length = parse_header(header, allowed=allowed)
        payload = self._in.read(length)
        if len(payload) != length:
            raise ProtocolError()
        return kind, payload

    def read_message(self, message_type: str) -> dict[str, Any] | None:
        read = self.read_frame(frozenset({KIND_JSON}))
        if read is None:
            return None
        return decode_message(read[1], expected=frozenset({message_type}))

    def send(self, message: dict[str, Any]) -> None:
        self._out.write(message_frame(message))
        self._out.flush()


def run(
    stdin: BinaryIO,
    stdout: BinaryIO,
    engines: Mapping[str, Callable[[], Engine]],
    verify: Callable[[Path], None] = verify_installation,
) -> int:
    """Serve one worker lifetime. Returns the exit status.

    `verify` hashes the installation against its install record before any
    engine is constructed (`hagig.models.verify_installation`).
    """
    stdout.write(READY_LINE)
    stdout.flush()
    try:
        return _serve(_Pipe(stdin, stdout), engines, verify)
    except ProtocolError:
        return 1


def _serve(
    pipe: _Pipe,
    engines: Mapping[str, Callable[[], Engine]],
    verify: Callable[[Path], None],
) -> int:
    load = pipe.read_message("load")
    if load is None:
        return 0
    generation = load["generation"]

    def fail(code: str, request_id: str | None) -> int:
        pipe.send(
            {
                "type": "error",
                "generation": generation,
                "request_id": request_id,
                "code": code,
            }
        )
        return 1

    if load["version"] != PROTOCOL_VERSION or load["engine"] not in engines:
        return fail("worker_failed", None)
    code = None
    try:
        verify(Path(load["model_dir"]))
        engine = engines[load["engine"]]()
        engine.load(Path(load["model_dir"]))
    except (EngineError, ModelError) as error:
        code = error.code if error.code in LOAD_CODES else "worker_failed"
    except Exception:
        code = "worker_failed"
    if code is not None:
        return fail(code, None)
    vocabulary = tuple(load["vocabulary"])
    pipe.send({"type": "loaded", "generation": generation})

    import numpy as np

    while True:
        request = pipe.read_message("transcribe")
        if request is None:
            return 0
        request_id = request["request_id"]
        if request["generation"] != generation:
            return fail("worker_failed", request_id)
        read = pipe.read_frame(frozenset({KIND_PCM}))
        if read is None or len(read[1]) != request["sample_count"] * 4:
            return fail("worker_failed", request_id)
        audio = np.frombuffer(read[1], dtype="<f4")
        try:
            text = engine.transcribe(audio, vocabulary)
            text.encode()
        except Exception:
            return fail("worker_failed", request_id)
        result = {
            "type": "result",
            "generation": generation,
            "request_id": request_id,
            "text": text,
        }
        try:
            pipe.send(result)
        except ProtocolError:
            # message_frame refused an envelope over the 64 KiB frame cap.
            return fail("result_too_large", request_id)


def main(engines: Mapping[str, Callable[[], Engine]] = ENGINES) -> None:
    os.environ.update(OFFLINE_ENV)
    # Keep the protocol stream to ourselves: anything else printed to fd 1
    # goes to stderr, which the server discards.
    protocol_out = os.fdopen(os.dup(1), "wb")
    os.dup2(2, 1)
    sys.stdout = sys.stderr
    protocol_in = os.fdopen(os.dup(0), "rb")
    raise SystemExit(run(protocol_in, protocol_out, engines))


if __name__ == "__main__":
    # `python -m hagig.worker` runs this file as `__main__`; engines import
    # `hagig.worker` for EngineError, so serve from that one module, or their
    # errors would be another class and every code would be worker_failed.
    importlib.import_module("hagig.worker").main()
