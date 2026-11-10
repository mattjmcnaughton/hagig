"""The single active request (TDD sections 6-7; backend/PROTOCOL.md).

One admitted request exists at a time, with no queue. It is reserved by
admission, claimed by its upload, then computed by the worker. Cancellation
(DELETE, upload disconnect, the upload-start or reservation deadline, stop)
invalidates it first; every terminal transition releases the audio and the slot
exactly once, after any worker the request retired has been reaped.
"""

import asyncio
import secrets
from collections.abc import Awaitable, Callable, MutableMapping
from dataclasses import dataclass
from typing import Any

import numpy as np

from hagig.config import Config
from hagig.contract import (
    API_VERSION,
    CLIENT_WAIT_SECONDS,
    COMPUTATION_SECONDS,
    ERROR_STATUSES,
    MAX_AUDIO_BYTES,
    MAX_JSON_BYTES,
    RESERVATION_SECONDS,
    UPLOAD_START_SECONDS,
    encode_json,
)
from hagig.services.supervisor import Supervisor, WorkerError

AUDIO_TYPE = "application/octet-stream"

Receive = Callable[[], Awaitable[MutableMapping[str, Any]]]


class RequestError(Exception):
    """A request ended with a stable error code and its HTTP status."""

    def __init__(self, code: str, status: int | None = None) -> None:
        super().__init__(code)
        self.code = code
        self.status = ERROR_STATUSES[code][0] if status is None else status


class DisconnectedError(Exception):
    """The upload connection closed; no response is delivered."""


@dataclass(frozen=True)
class Deadlines:
    """Server-enforced deadlines in seconds (PROTOCOL.md, Deadlines)."""

    upload_start: float = UPLOAD_START_SECONDS
    reservation: float = RESERVATION_SECONDS
    computation: float = COMPUTATION_SECONDS


@dataclass(eq=False)
class _Active:
    request_id: str
    cancelled: "asyncio.Future[RequestError]"
    upload_start_timer: asyncio.TimerHandle
    reservation_timer: asyncio.TimerHandle
    claimed: bool = False


def new_token() -> str:
    """192 random bits in the request-ID alphabet `[A-Za-z0-9_-]`."""
    return secrets.token_urlsafe(24)


class RequestService:
    def __init__(
        self, config: Config, supervisor: Supervisor, deadlines: Deadlines
    ) -> None:
        self._config = config
        self._supervisor = supervisor
        self._deadlines = deadlines
        self._config_generation = new_token()
        self._active: _Active | None = None
        self._idle = asyncio.Event()
        self._idle.set()
        self._stopping = False
        self.stop_requested = asyncio.Event()

    @property
    def _busy(self) -> bool:
        return self._active is not None or self._supervisor.reaping

    def status(self) -> dict[str, Any]:
        """The content-free status object, in the contract's field order."""
        if self._stopping:
            raise RequestError("server_stopping")
        return {
            "api_version": API_VERSION,
            "state": "busy" if self._busy else "idle",
            "worker": "running" if self._supervisor.running else "absent",
            "network_isolation": self._config.inference.network_isolation,
            "config_generation": self._config_generation,
            "settings": {
                "editor_mode": self._config.editor.mode,
                "model_id": self._config.model.id,
                "language": "en",
            },
            "audio": {"encoding": "f32le", "sample_rate_hz": 16000, "channels": 1},
            "limits": {
                "json_body_bytes": MAX_JSON_BYTES,
                "result_body_bytes": MAX_JSON_BYTES,
                "audio_bytes": MAX_AUDIO_BYTES,
            },
            # The contract's values, not any injected test deadlines.
            "deadlines": {
                "upload_start_seconds": UPLOAD_START_SECONDS,
                "reservation_seconds": RESERVATION_SECONDS,
                "computation_seconds": COMPUTATION_SECONDS,
                "client_wait_seconds": CLIENT_WAIT_SECONDS,
            },
        }

    def admit(self) -> dict[str, str]:
        if self._stopping:
            raise RequestError("server_stopping")
        if self._busy:
            raise RequestError("busy")
        loop = asyncio.get_running_loop()
        request_id = new_token()
        deadlines = self._deadlines
        active = _Active(
            request_id,
            loop.create_future(),
            # Claiming the upload cancels this timer, so it only ever releases
            # an unclaimed reservation.
            upload_start_timer=loop.call_later(
                deadlines.upload_start, lambda: self._release(active)
            ),
            reservation_timer=loop.call_later(
                deadlines.reservation,
                lambda: self._invalidate(active, RequestError("deadline_exceeded")),
            ),
        )
        self._active = active
        self._idle.clear()
        return {
            "request_id": active.request_id,
            "config_generation": self._config_generation,
            "model_id": self._config.model.id,
        }

    def cancel(self, request_id: str) -> None:
        active = self._active
        if active is not None and active.request_id == request_id:
            self._invalidate(active, RequestError("cancelled"))

    def stop(self) -> None:
        self._stopping = True
        self.stop_requested.set()
        if self._active is not None:
            self._invalidate(self._active, RequestError("server_stopping"))

    async def drain(self) -> None:
        """After stop: wait for active work to answer, then reap the worker."""
        await self._idle.wait()
        await self._supervisor.shutdown()

    def _invalidate(self, active: _Active, failure: RequestError) -> None:
        if not active.claimed:
            # Nobody is uploading: the reservation simply ends.
            self._release(active)
        elif not active.cancelled.done():
            active.cancelled.set_result(failure)

    def _release(self, active: _Active) -> None:
        if self._active is not active:
            return
        self._active = None
        active.upload_start_timer.cancel()
        active.reservation_timer.cancel()
        self._idle.set()

    async def upload(
        self,
        request_id: str,
        content_type: str | None,
        content_length: int | None,
        receive: Receive,
    ) -> bytes:
        """Own the request through its upload connection; return the 200 body.

        Raises RequestError for a response, or DisconnectedError for none.
        """
        if self._stopping:
            raise RequestError("server_stopping")
        active = self._active
        if active is None or active.request_id != request_id or active.claimed:
            raise RequestError("request_not_found")
        active.claimed = True
        active.upload_start_timer.cancel()
        try:
            if content_type != AUDIO_TYPE:
                raise RequestError("invalid_request")
            if content_length is not None and content_length > MAX_AUDIO_BYTES:
                raise RequestError("invalid_audio", 413)
            audio = await self._receive_audio(active, receive)
            # The reservation ends with the body; computation starts.
            active.reservation_timer.cancel()
            return await self._compute(active, audio, receive)
        finally:
            await self._supervisor.wait_reaped()
            self._release(active)

    async def _receive_audio(self, active: _Active, receive: Receive) -> bytearray:
        validator = AudioValidator()
        while True:
            message = await _first(active.cancelled, asyncio.ensure_future(receive()))
            if message["type"] != "http.request":
                raise DisconnectedError()
            validator.feed(message.get("body", b""))
            if not message.get("more_body", False):
                return validator.finish()

    async def _compute(
        self, active: _Active, audio: bytearray, receive: Receive
    ) -> bytes:
        work = asyncio.ensure_future(
            self._supervisor.transcribe(active.request_id, audio)
        )
        del audio
        # After the body, receive() only returns when the client disconnects.
        disconnect = asyncio.ensure_future(receive())
        try:
            done, _ = await asyncio.wait(
                {work, disconnect, active.cancelled},
                timeout=self._deadlines.computation,
                return_when=asyncio.FIRST_COMPLETED,
            )
            # Invalidation wins over a result that arrived with it.
            if active.cancelled.done():
                raise active.cancelled.result()
            if disconnect in done:
                raise DisconnectedError()
            if work not in done:
                raise RequestError("deadline_exceeded")
            try:
                text = work.result()
            except WorkerError as failure:
                raise RequestError(failure.code) from None
            # The one change to the worker's text (PROTOCOL.md, Result text).
            return result_body("" if text.isspace() else text)
        finally:
            for task in (work, disconnect):
                task.cancel()
            # Let a cancelled transcription retire its worker before reaping.
            await asyncio.wait({work, disconnect})


async def _first(
    cancelled: "asyncio.Future[RequestError]", task: asyncio.Future
) -> Any:
    try:
        await asyncio.wait({cancelled, task}, return_when=asyncio.FIRST_COMPLETED)
    finally:
        if not task.done():
            task.cancel()
    if cancelled.done():
        raise cancelled.result()
    return task.result()


def result_body(text: str) -> bytes:
    """The serialized `{"text": ...}` response; it must fit 64 KiB, untruncated."""
    body = encode_json({"text": text})
    if len(body) > MAX_JSON_BYTES:
        raise RequestError("result_too_large")
    return body


class AudioValidator:
    """Validates canonical f32le audio as it arrives, across any chunking."""

    def __init__(self) -> None:
        self._audio = bytearray()

    def feed(self, chunk: bytes) -> None:
        # Bytes are judged in stream order: samples before the cap are checked
        # first, so a bad sample wins over a later byte past the cap.
        room = MAX_AUDIO_BYTES - len(self._audio)
        over_cap = len(chunk) > room
        # Samples before `start` are checked; an incomplete trailing sample
        # waits for the next chunk.
        start = len(self._audio) - len(self._audio) % 4
        self._audio += chunk[:room] if over_cap else chunk
        end = len(self._audio) - len(self._audio) % 4
        if end > start:
            # Slicing copies, so no buffer export pins the growing bytearray.
            samples = np.frombuffer(self._audio[start:end], dtype="<f4")
            if not (np.isfinite(samples).all() and (np.abs(samples) <= 1).all()):
                raise RequestError("invalid_audio")
        if over_cap:
            raise RequestError("invalid_audio", 413)

    def finish(self) -> bytearray:
        if not self._audio or len(self._audio) % 4:
            raise RequestError("invalid_audio")
        return self._audio
