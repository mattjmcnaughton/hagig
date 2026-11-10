"""The CLI's REST client over the private socket (PROTOCOL.md, Client rules).

Each endpoint method classifies its response into one `Outcome`; anything
unexpected is a `generic_failure`, never success. Bodies are read with a
64 KiB bound.
"""

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import httpx

from hagig.contract import (
    API_VERSION,
    CLIENT_WAIT_SECONDS,
    ERROR_STATUSES,
    EXCHANGE_SECONDS,
    MAX_JSON_BYTES,
    REQUEST_ID,
    is_int,
)

_ENUMS = {
    "state": {"idle", "busy"},
    "worker": {"absent", "running"},
    "network_isolation": {"required", "disabled"},
}
_INTS = {
    "audio": ("sample_rate_hz", "channels"),
    "limits": ("json_body_bytes", "result_body_bytes", "audio_bytes"),
    "deadlines": (
        "upload_start_seconds",
        "reservation_seconds",
        "computation_seconds",
        "client_wait_seconds",
    ),
}


class UnreachableError(Exception):
    """No server answers on the socket (absent, or a stale socket)."""


@dataclass(frozen=True)
class Outcome:
    """`kind` is a PROTOCOL.md client outcome; `data` holds a 201 or status body."""

    kind: str
    code: str | None = None
    text: str | None = None
    data: dict[str, Any] = field(default_factory=dict)


GENERIC = Outcome("generic_failure")
_Response = tuple[int, dict[str, Any] | None]


def _object(body: bytes) -> dict[str, Any] | None:
    if len(body) > MAX_JSON_BYTES:
        return None
    try:
        value = json.loads(body)
    except (ValueError, RecursionError):
        return None
    return value if isinstance(value, dict) else None


def _token(value: object) -> bool:
    return isinstance(value, str) and REQUEST_ID.fullmatch(value) is not None


def compatible_status(data: dict[str, Any]) -> bool:
    if not is_int(data.get("api_version")) or data["api_version"] != API_VERSION:
        return False
    if any(data.get(name) not in values for name, values in _ENUMS.items()):
        return False
    if not _token(data.get("config_generation")):
        return False
    settings = data.get("settings")
    if not isinstance(settings, dict):
        return False
    if settings.get("editor_mode") not in {"standard", "vim"}:
        return False
    if not all(isinstance(settings.get(n), str) for n in ("model_id", "language")):
        return False
    for table, names in _INTS.items():
        section = data.get(table)
        if not isinstance(section, dict):
            return False
        if not all(is_int(section.get(n)) for n in names):
            return False
    # `audio` was checked to be an object above.
    return isinstance(data["audio"].get("encoding"), str)


def _failure(response: _Response) -> Outcome:
    """An error the table lists for its status, or a generic failure."""
    status, data = response
    code = data.get("code") if data is not None else None
    if isinstance(code, str) and status in ERROR_STATUSES.get(code, ()):
        return Outcome("failure", code=code)
    return GENERIC


class Client:
    def __init__(self, socket: Path) -> None:
        self._http = httpx.Client(
            transport=httpx.HTTPTransport(uds=str(socket)),
            base_url="http://localhost",
            timeout=EXCHANGE_SECONDS,
            # No proxies, .netrc or other environment configuration.
            trust_env=False,
        )

    def __enter__(self) -> "Client":
        return self

    def __exit__(self, *_exc: object) -> None:
        self._http.close()

    def _send(
        self,
        method: str,
        path: str,
        *,
        content: bytes | None = None,
        timeout: httpx.Timeout | float = EXCHANGE_SECONDS,
    ) -> _Response:
        """Raise UnreachableError if nothing accepts the connection."""
        headers = {}
        if content is not None:
            headers["content-type"] = "application/octet-stream"
        elif method in ("POST", "PUT"):
            headers["content-length"] = "0"
        try:
            with self._http.stream(
                method, path, content=content, headers=headers, timeout=timeout
            ) as response:
                body = bytearray()
                for part in response.iter_bytes():
                    body += part
                    if len(body) > MAX_JSON_BYTES:
                        break
                return response.status_code, _object(bytes(body))
        except httpx.ConnectError:
            pass
        raise UnreachableError()

    def _exchange(self, method: str, path: str) -> _Response | None:
        """A status, admission, DELETE or stop exchange; None on any failure."""
        try:
            return self._send(method, path)
        except (httpx.HTTPError, httpx.StreamError, UnreachableError):
            return None

    def status(self) -> Outcome:
        """Raise UnreachableError if no server answers; never start one."""
        try:
            status, data = self._send("GET", "/v1/status")
        except (httpx.HTTPError, httpx.StreamError):
            return Outcome("incompatible_api")
        if status == 503 and data is not None and data.get("code") == "server_stopping":
            return Outcome("failure", code="server_stopping")
        if status == 200 and data is not None and compatible_status(data):
            return Outcome("compatible", data=data)
        return Outcome("incompatible_api")

    def admit(self) -> Outcome:
        response = self._exchange("POST", "/v1/requests")
        if response is None:
            return GENERIC
        status, data = response
        if status != 201:
            return _failure(response)
        if (
            data is not None
            and _token(data.get("request_id"))
            and isinstance(data.get("config_generation"), str)
            and isinstance(data.get("model_id"), str)
        ):
            return Outcome("admitted", data=data)
        return GENERIC

    def upload(self, request_id: str, audio: bytes) -> Outcome:
        # The client wait runs from the end of the body to the response head.
        timeout = httpx.Timeout(EXCHANGE_SECONDS, read=CLIENT_WAIT_SECONDS)
        try:
            response = self._send(
                "PUT",
                f"/v1/requests/{request_id}/audio",
                content=audio,
                timeout=timeout,
            )
        except httpx.ReadTimeout:
            return Outcome("failure", code="deadline_exceeded")
        except (httpx.HTTPError, httpx.StreamError, UnreachableError):
            return GENERIC
        status, data = response
        if status != 200:
            return _failure(response)
        text = data.get("text") if data is not None else None
        if not isinstance(text, str):
            return GENERIC
        return Outcome("text", text=text) if text else Outcome("empty")

    def cancel(self, request_id: str) -> Outcome:
        response = self._exchange("DELETE", f"/v1/requests/{request_id}")
        if response is not None and response[0] == 204:
            return Outcome("cancel_acknowledged")
        return GENERIC if response is None else _failure(response)

    def stop(self) -> Outcome:
        response = self._exchange("POST", "/v1/stop")
        if response is not None and response[0] == 202:
            return Outcome("stop_acknowledged")
        return GENERIC if response is None else _failure(response)
