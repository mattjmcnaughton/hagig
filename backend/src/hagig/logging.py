"""Structured, content-free logging (TDD section 10).

Logs go to stderr as JSON, and, when a log file is given, to that file too. Only
allowlisted field names with scalar values survive, so content passed under any
other key, and exceptions or structured values under any key, are dropped. The
filter does not inspect scalar values: callers must pass fixed event names and
stable codes, never transcripts, vocabulary, paths or error text. Call
`configure_logging()` once at a process entry point.

The log file is opened `O_NOFOLLOW` and must be a regular 0600 file we own.
When it would grow past `MAX_LOG_BYTES` it is renamed to `<name>.1`, replacing
the previous one, and a new file is started. A file that cannot be opened or
written is skipped silently: logging never stops the process.
"""

import contextlib
import os
import stat
import sys
from collections.abc import MutableMapping
from pathlib import Path
from typing import Any, Self, TextIO

import structlog

CONTENT_FREE_FIELDS = frozenset(
    {
        "event",
        "level",
        "timestamp",
        "code",
        "stage",
        "field",
        "mode",
        "version",
        "count",
        "duration_ms",
        # A worker process's exit status (negative: the signal number).
        "exit_status",
    }
)

MAX_LOG_BYTES = 1 << 20


def _keep_content_free_fields(
    _logger: Any, _method: str, event_dict: MutableMapping[str, Any]
) -> dict[str, Any]:
    return {
        key: value
        for key, value in event_dict.items()
        if key in CONTENT_FREE_FIELDS and isinstance(value, str | int | float | None)
    }


class LogFile:
    """Appends lines to a private file, rotating it at a size bound."""

    def __init__(self, path: Path, fd: int, max_bytes: int) -> None:
        self._path = path
        self._fd = fd
        self._max_bytes = max_bytes

    @classmethod
    def open(cls, path: Path, *, max_bytes: int = MAX_LOG_BYTES) -> Self | None:
        """Open `path` for appending, or None if it is unavailable or unsafe."""
        fd = _open_private(path)
        return None if fd < 0 else cls(path, fd, max_bytes)

    def write(self, line: str) -> None:
        if self._fd < 0:
            return
        data = line.encode() + b"\n"
        try:
            if os.fstat(self._fd).st_size + len(data) > self._max_bytes:
                self._rotate()
            if self._fd >= 0:
                os.write(self._fd, data)
        except OSError:
            # Nothing to report it to; never fall back to an unbounded file.
            self.close()

    def close(self) -> None:
        if self._fd >= 0:
            with contextlib.suppress(OSError):
                os.close(self._fd)
            self._fd = -1

    def _rotate(self) -> None:
        current = os.fstat(self._fd).st_ino
        self.close()
        with contextlib.suppress(FileNotFoundError):
            # Only our own file: another process may already have rotated it.
            if os.lstat(self._path).st_ino == current:
                os.replace(self._path, self._path.with_name(self._path.name + ".1"))
        self._fd = _open_private(self._path)


def _open_private(path: Path) -> int:
    flags = (
        os.O_WRONLY
        | os.O_APPEND
        | os.O_CREAT
        | os.O_NOFOLLOW
        | os.O_NONBLOCK
        | os.O_CLOEXEC
    )
    try:
        fd = os.open(path, flags, 0o600)
    except OSError:
        return -1
    info = os.fstat(fd)
    if (
        not stat.S_ISREG(info.st_mode)
        or info.st_uid != os.getuid()
        or stat.S_IMODE(info.st_mode) != 0o600
    ):
        os.close(fd)
        return -1
    return fd


class _Logger:
    """structlog's final logger: one rendered line to stderr and the file."""

    def __init__(self, stream: TextIO, file: LogFile | None) -> None:
        self._stream = stream
        self._file = file

    def msg(self, message: str) -> None:
        with contextlib.suppress(OSError, ValueError):
            print(message, file=self._stream, flush=True)
        if self._file is not None:
            self._file.write(message)

    log = debug = info = warn = warning = error = critical = exception = fatal = msg


def configure_logging(log_file: LogFile | None = None) -> None:
    """Configure structlog for the application, optionally also into `log_file`."""
    logger = _Logger(sys.stderr, log_file)
    structlog.configure(
        processors=[
            structlog.processors.add_log_level,
            structlog.processors.TimeStamper(fmt="iso"),
            _keep_content_free_fields,
            structlog.processors.JSONRenderer(),
        ],
        wrapper_class=structlog.make_filtering_bound_logger("info"),
        logger_factory=lambda *_args: logger,
        cache_logger_on_first_use=False,
    )
