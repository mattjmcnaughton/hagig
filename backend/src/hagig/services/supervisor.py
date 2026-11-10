"""Worker supervision (TDD sections 6-7; backend/PROTOCOL.md).

One worker process at a time, launched lazily with `asyncio.create_subprocess_exec`
and spoken to only over its stdin/stdout. Each launch gets a new generation, and
a reply is accepted only when its type, generation and request ID are exactly the
ones expected. Anything else, including a stray byte while idle, retires the
worker: close its stdin, wait 1 s, SIGTERM its process group, wait 1 s, SIGKILL,
and always reap. A successor is never launched before its predecessor is reaped.
Rejected worker bytes are never logged, returned or echoed.
"""

import asyncio
import contextlib
import os
import signal
from asyncio.subprocess import PIPE, Process
from collections.abc import Generator, Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import structlog

from hagig.config import ModelId, NetworkIsolation
from hagig.framing import (
    HEADER,
    KIND_JSON,
    KIND_PCM,
    LOAD_CODES,
    PROTOCOL_VERSION,
    READY_LINE,
    ProtocolError,
    decode_message,
    message_frame,
    parse_header,
)
from hagig.launcher import Launcher
from hagig.models import ENGINE_BY_MODEL, installed_model_dir

log = structlog.get_logger()

_TRANSCRIBE_CODES = frozenset({"result_too_large"})
_POLL_SECONDS = 0.01


class WorkerError(Exception):
    """A request failed in the worker path. `code` is a stable REST error code."""

    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


@dataclass(frozen=True)
class WorkerSettings:
    """Everything the supervisor needs, frozen at server startup."""

    launcher: Launcher
    mode: NetworkIsolation
    # The worker's whole environment (`launcher.worker_env`), not the server's.
    env: Mapping[str, str]
    models_root: Path
    model_id: ModelId
    vocabulary: tuple[str, ...]
    # Each step of the retirement escalation (TDD section 7).
    grace_seconds: float = 1.0


@dataclass(eq=False)
class _Worker:
    process: Process
    stdin: asyncio.StreamWriter
    stdout: asyncio.StreamReader
    generation: int
    retired: bool = False
    watch: "asyncio.Task[bytes] | None" = None


class Supervisor:
    def __init__(self, settings: WorkerSettings) -> None:
        self._settings = settings
        self._generation = 0
        self._worker: _Worker | None = None
        self._reaps: set[asyncio.Task[None]] = set()

    @property
    def running(self) -> bool:
        """A worker process is owned: starting, loading, warm, computing or reaping."""
        return self._worker is not None or bool(self._reaps)

    @property
    def reaping(self) -> bool:
        return bool(self._reaps)

    async def wait_reaped(self) -> None:
        """Wait until every retired worker has been reaped."""
        while self._reaps:
            await asyncio.wait(set(self._reaps))

    async def shutdown(self) -> None:
        if self._worker is not None:
            self._retire(self._worker, "shutdown")
        await self.wait_reaped()

    async def transcribe(self, request_id: str, audio: bytes | bytearray) -> str:
        """Run one request on the warm worker, launching one if needed.

        Raises WorkerError. Any failure or cancellation once a worker is in
        use retires it; callers wait with `wait_reaped` before answering.
        """
        await self.wait_reaped()
        worker = await self._take_warm() or await self._start()
        with self._retire_on_failure(worker):
            return await self._request(worker, request_id, audio)

    @contextlib.contextmanager
    def _retire_on_failure(self, worker: _Worker) -> Generator[None]:
        try:
            yield
        except WorkerError as failure:
            self._retire(worker, failure.code)
            raise
        except BaseException:
            self._retire(worker, "cancelled")
            raise

    async def _take_warm(self) -> _Worker | None:
        worker = self._worker
        if worker is None:
            return None
        watch, worker.watch = worker.watch, None
        if watch is not None:
            watch.cancel()
            # A StreamReader allows one waiter, so the watch must finish first.
            # Its callback has retired the worker if it saw a byte or EOF.
            try:
                await asyncio.wait({watch})
                # Output that arrived as the watch was cancelled stays unread.
                if watch.cancelled() and _output_pending(worker.stdout):
                    self._retire(worker, "worker_protocol")
            except asyncio.CancelledError:
                # Cancelled before the request reached the worker: it stays
                # warm and watched (asyncio delivers the cancellation once).
                await asyncio.wait({watch})
                if not worker.retired:
                    self._watch(worker)
                raise
        if worker.retired:
            await self.wait_reaped()
            return None
        return worker

    async def _start(self) -> _Worker:
        settings = self._settings
        model_dir = installed_model_dir(settings.models_root, settings.model_id)
        if model_dir is None:
            raise WorkerError("model_missing")
        argv = settings.launcher.argv(settings.mode)
        if argv is None:
            raise WorkerError("isolation_unavailable")
        process = None
        with contextlib.suppress(OSError):
            process = await asyncio.create_subprocess_exec(
                *argv,
                stdin=PIPE,
                stdout=PIPE,
                stderr=asyncio.subprocess.DEVNULL,
                env=dict(settings.env),
                cwd="/",
                close_fds=True,
                start_new_session=True,
            )
        if process is None:
            raise WorkerError(self._launch_failure())
        assert process.stdin is not None and process.stdout is not None
        self._generation += 1
        worker = _Worker(process, process.stdin, process.stdout, self._generation)
        self._worker = worker
        log.info("worker_launched", mode=settings.mode, version=worker.generation)
        with self._retire_on_failure(worker):
            await self._handshake(worker, model_dir)
        return worker

    def _launch_failure(self) -> str:
        # A refused Seatbelt policy looks like any other launch failure.
        if self._settings.mode == "required":
            return "isolation_unavailable"
        return "worker_failed"

    async def _handshake(self, worker: _Worker, model_dir: Path) -> None:
        launched = True
        try:
            ready = await worker.stdout.readexactly(len(READY_LINE))
        except asyncio.IncompleteReadError as error:
            # Exiting before (or partway through) the ready line is a launch
            # failure; any other bytes are a protocol failure.
            launched = not READY_LINE.startswith(error.partial)
            ready = b""
        if not launched:
            raise WorkerError(self._launch_failure())
        if ready != READY_LINE:
            raise WorkerError("worker_failed")
        settings = self._settings
        load = None
        with contextlib.suppress(ProtocolError):
            load = message_frame(
                {
                    "type": "load",
                    "version": PROTOCOL_VERSION,
                    "generation": worker.generation,
                    "engine": ENGINE_BY_MODEL[settings.model_id],
                    "model_dir": str(model_dir),
                    "vocabulary": list(settings.vocabulary),
                }
            )
        if load is None:
            # Configuration caps keep `load` under the frame cap; fail closed.
            raise WorkerError("worker_failed")
        await self._send(worker, load)
        reply = await self._reply(worker, None, frozenset({"loaded", "error"}))
        if reply["type"] == "error":
            code = reply["code"]
            raise WorkerError(code if code in LOAD_CODES else "worker_failed")

    async def _request(
        self, worker: _Worker, request_id: str, audio: bytes | bytearray
    ) -> str:
        message = {
            "type": "transcribe",
            "generation": worker.generation,
            "request_id": request_id,
            "sample_count": len(audio) // 4,
        }
        await self._send(
            worker, message_frame(message), HEADER.pack(KIND_PCM, len(audio)), audio
        )
        reply = await self._reply(worker, request_id, frozenset({"result", "error"}))
        if reply["type"] == "error":
            code = reply["code"]
            raise WorkerError(code if code in _TRANSCRIBE_CODES else "worker_failed")
        self._watch(worker)
        return reply["text"]

    async def _send(self, worker: _Worker, *parts: bytes | bytearray) -> None:
        for part in parts:
            worker.stdin.write(part)
        broken = False
        try:
            await worker.stdin.drain()
        except (BrokenPipeError, ConnectionResetError):
            broken = True
        if broken:
            raise WorkerError("worker_failed")

    async def _reply(
        self, worker: _Worker, request_id: str | None, expected: frozenset[str]
    ) -> dict[str, Any]:
        reply = None
        with contextlib.suppress(asyncio.IncompleteReadError, ProtocolError):
            header = await worker.stdout.readexactly(HEADER.size)
            _kind, length = parse_header(header, allowed=frozenset({KIND_JSON}))
            payload = await worker.stdout.readexactly(length)
            reply = decode_message(payload, expected=expected)
        if (
            reply is None
            or reply["generation"] != worker.generation
            or reply.get("request_id") != request_id
        ):
            raise WorkerError("worker_failed")
        return reply

    def _watch(self, worker: _Worker) -> None:
        """While idle, any stdout byte or EOF retires the worker."""
        watch = asyncio.create_task(worker.stdout.read(1))
        worker.watch = watch

        def idle_output(task: "asyncio.Task[bytes]") -> None:
            if not task.cancelled():
                task.exception()  # retrieved, never logged
                self._retire(worker, "worker_protocol")

        watch.add_done_callback(idle_output)

    def _retire(self, worker: _Worker, stage: str) -> None:
        if worker.retired:
            return
        worker.retired = True
        if self._worker is worker:
            self._worker = None
        if worker.watch is not None:
            worker.watch.cancel()
            worker.watch = None
        log.info("worker_retired", stage=stage, version=worker.generation)
        task = asyncio.create_task(self._reap(worker))
        self._reaps.add(task)
        task.add_done_callback(self._reaps.discard)

    async def _reap(self, worker: _Worker) -> None:
        process = worker.process
        # Exit request: close stdin, dropping any audio still buffered for it.
        worker.stdin.transport.abort()
        grace = self._settings.grace_seconds
        for sig in (signal.SIGTERM, signal.SIGKILL):
            if await _exited(process, grace):
                break
            # Group signals only while unreaped, so the group ID is still ours.
            if process.returncode is None:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(process.pid, sig)
        while process.returncode is None:
            await asyncio.sleep(_POLL_SECONDS)
        # The process is gone, so its stdout ends after at most a pipe's worth.
        with contextlib.suppress(TimeoutError):
            await asyncio.wait_for(_discard(worker.stdout), grace)


def _output_pending(stdout: asyncio.StreamReader) -> bool:
    """Buffered bytes or EOF that no reader has consumed.

    StreamReader has no public peek; `_buffer` and `_eof` are CPython's.
    """
    return bool(getattr(stdout, "_buffer", b"")) or bool(getattr(stdout, "_eof", False))


async def _exited(process: Process, timeout: float) -> bool:
    # Poll the reaped status rather than `wait()`, which also waits for the
    # pipes to close and could hang on a paused, unread stdout.
    loop = asyncio.get_running_loop()
    end = loop.time() + timeout
    while process.returncode is None and loop.time() < end:
        await asyncio.sleep(_POLL_SECONDS)
    return process.returncode is not None


async def _discard(stdout: asyncio.StreamReader) -> None:
    while await stdout.read(65_536):
        pass
