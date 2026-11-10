"""REST API v1 constants shared by the server, the CLI and the worker pipe.

Every value here is fixed by backend/PROTOCOL.md; a change is a new API
version. Standard library only, because the worker imports it through framing.
"""

import json
import re
from typing import Any, TypeGuard

API_VERSION = 1

# Every JSON body, REST or worker frame, is at most this many bytes.
MAX_JSON_BYTES = 65_536
# Canonical f32le audio: 300 s of 16 kHz mono.
MAX_AUDIO_BYTES = 19_200_000

# Request IDs and config generations.
REQUEST_ID = re.compile(r"[A-Za-z0-9_-]{1,128}")

UPLOAD_START_SECONDS = 5
RESERVATION_SECONDS = 330
COMPUTATION_SECONDS = 120
CLIENT_WAIT_SECONDS = 125
# Startup/connect and the status, admission, DELETE and stop exchanges.
EXCHANGE_SECONDS = 5

# Stable error codes and the statuses each may carry; the first is the default.
ERROR_STATUSES: dict[str, tuple[int, ...]] = {
    "invalid_request": (400,),
    "invalid_audio": (400, 413),
    "request_not_found": (404,),
    "busy": (409,),
    "cancelled": (409,),
    "model_missing": (503,),
    "model_invalid": (503,),
    "isolation_unavailable": (503,),
    "server_stopping": (503,),
    "worker_failed": (500,),
    "result_too_large": (500,),
    "deadline_exceeded": (504,),
}


def is_int(value: object) -> TypeGuard[int]:
    """A JSON integer: an int that is not a bool."""
    return isinstance(value, int) and not isinstance(value, bool)


def encode_json(value: dict[str, Any]) -> bytes:
    """The compact encoding that defines every byte size in the contract."""
    return json.dumps(
        value, ensure_ascii=False, allow_nan=False, separators=(",", ":")
    ).encode()
