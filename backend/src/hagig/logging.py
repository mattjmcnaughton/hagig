"""Structured, content-free logging (TDD section 10).

Logs go to stderr as JSON. Only allowlisted field names with scalar values
survive, so content passed under any other key, and exceptions or structured
values under any key, are dropped. The filter does not inspect scalar values:
callers must pass fixed event names and stable codes, never transcripts,
vocabulary, paths or error text. Call `configure_logging()` once at a process
entry point.
"""

import sys
from collections.abc import MutableMapping
from typing import Any

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
    }
)


def _keep_content_free_fields(
    _logger: Any, _method: str, event_dict: MutableMapping[str, Any]
) -> dict[str, Any]:
    return {
        key: value
        for key, value in event_dict.items()
        if key in CONTENT_FREE_FIELDS and isinstance(value, str | int | float | None)
    }


def configure_logging() -> None:
    """Configure structlog for the application."""
    structlog.configure(
        processors=[
            structlog.processors.add_log_level,
            structlog.processors.TimeStamper(fmt="iso"),
            _keep_content_free_fields,
            structlog.processors.JSONRenderer(),
        ],
        wrapper_class=structlog.make_filtering_bound_logger("info"),
        logger_factory=structlog.PrintLoggerFactory(sys.stderr),
    )
