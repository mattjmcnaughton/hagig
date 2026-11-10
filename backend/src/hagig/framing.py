"""Worker pipe framing and messages (backend/PROTOCOL.md, "Worker pipe protocol").

Shared by the server and the worker, so it imports only the standard library.
Every frame is `kind:u8 | length:u32 big-endian | payload`. Headers are validated
before anything is allocated, and messages must have exactly the listed fields.
Errors carry no frame content.
"""

import contextlib
import json
import struct
from collections.abc import Callable
from typing import Any

from hagig.contract import (
    MAX_AUDIO_BYTES,
    MAX_JSON_BYTES,
    REQUEST_ID,
    encode_json,
    is_int,
)

READY_LINE = b"HAGIG-WORKER-READY-v1\n"
PROTOCOL_VERSION = 1

KIND_JSON = 1
KIND_PCM = 2
HEADER = struct.Struct(">BI")
# kind -> (smallest, largest) payload; PCM must also be whole samples.
_LENGTHS = {KIND_JSON: (1, MAX_JSON_BYTES), KIND_PCM: (4, MAX_AUDIO_BYTES)}

# The worker's `load` error codes; anything else is `worker_failed`.
LOAD_CODES = frozenset({"model_missing", "model_invalid"})

# Set in the worker's launch environment and again in the worker before any
# engine import (TDD section 2).
OFFLINE_ENV = {
    "HF_HUB_OFFLINE": "1",
    "TRANSFORMERS_OFFLINE": "1",
    "HF_HUB_DISABLE_TELEMETRY": "1",
    "DO_NOT_TRACK": "1",
}


class ProtocolError(Exception):
    """A frame or message broke the protocol. Content-free by construction."""

    def __init__(self) -> None:
        super().__init__("worker_protocol")


def message_frame(message: dict[str, Any]) -> bytes:
    """Encode a kind-1 frame, or raise ProtocolError if it exceeds the cap."""
    payload = encode_json(message)
    if len(payload) > MAX_JSON_BYTES:
        raise ProtocolError()
    return HEADER.pack(KIND_JSON, len(payload)) + payload


def parse_header(header: bytes, *, allowed: frozenset[int]) -> tuple[int, int]:
    """Validate a 5-byte header before the payload is read or allocated."""
    kind, length = HEADER.unpack(header)
    if kind not in allowed:
        raise ProtocolError()
    low, high = _LENGTHS[kind]
    if not low <= length <= high or (kind == KIND_PCM and length % 4):
        raise ProtocolError()
    return kind, length


def _positive(value: object) -> bool:
    return is_int(value) and value > 0


def _request_id(value: object) -> bool:
    return isinstance(value, str) and REQUEST_ID.fullmatch(value) is not None


def _string_list(value: object) -> bool:
    return isinstance(value, list) and all(isinstance(item, str) for item in value)


_Check = Callable[[object], bool]

_SCHEMAS: dict[str, dict[str, _Check]] = {
    "load": {
        "version": is_int,
        "generation": _positive,
        "engine": lambda v: isinstance(v, str),
        "model_dir": lambda v: isinstance(v, str) and v.startswith("/"),
        "vocabulary": _string_list,
    },
    "loaded": {"generation": _positive},
    "transcribe": {
        "generation": _positive,
        "request_id": _request_id,
        "sample_count": _positive,
    },
    "result": {
        "generation": _positive,
        "request_id": _request_id,
        "text": lambda v: isinstance(v, str),
    },
    "error": {
        "generation": _positive,
        "request_id": lambda v: v is None or _request_id(v),
        "code": lambda v: isinstance(v, str),
    },
}


def _no_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result = dict(pairs)
    if len(result) != len(pairs):
        raise ValueError
    return result


def _reject(_value: str) -> Any:
    raise ValueError


def decode_message(payload: bytes, *, expected: frozenset[str]) -> dict[str, Any]:
    """Parse a kind-1 payload into a message whose `type` is in `expected`."""
    message = None
    # Every parser failure, including recursion limits and escaped lone
    # surrogates (which re-encoding rejects), becomes ProtocolError, raised
    # outside the handler so no content is chained onto it.
    with contextlib.suppress(ValueError, RecursionError):
        parsed = json.loads(
            payload.decode("utf-8"),
            object_pairs_hook=_no_duplicates,
            parse_float=_reject,
            parse_constant=_reject,
        )
        if isinstance(parsed, dict):
            encode_json(parsed)
            message = parsed
    if message is None:
        raise ProtocolError()
    kind = message.get("type")
    schema = _SCHEMAS.get(kind) if isinstance(kind, str) else None
    if kind not in expected or schema is None:
        raise ProtocolError()
    if message.keys() != {"type", *schema} or not all(
        check(message[name]) for name, check in schema.items()
    ):
        raise ProtocolError()
    return message
