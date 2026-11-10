import json

import pytest
import structlog

from hagig.logging import configure_logging

SENTINEL = "SENTINEL-vocabulary-Ghostty"


@pytest.fixture
def restore_structlog():
    """configure_logging binds the stream it is given (here capsys's, closed
    after the test); restore structlog's defaults so later in-process tests
    never log to it."""
    yield
    structlog.reset_defaults()


@pytest.mark.usefixtures("restore_structlog")
def test_logs_are_json_on_stderr_with_only_content_free_fields(capsys):
    configure_logging()
    log = structlog.get_logger()
    try:
        raise ValueError(SENTINEL)
    except ValueError:
        log.error(
            "config_invalid",
            code="invalid_value",
            field="vocabulary.terms",
            vocabulary=[SENTINEL],
            path=f"/home/{SENTINEL}/config.toml",
            stage=OSError(2, SENTINEL),
            count=[SENTINEL],
            exc_info=True,
        )

    captured = capsys.readouterr()
    assert captured.out == ""
    assert SENTINEL not in captured.err
    record = json.loads(captured.err)
    assert record["event"] == "config_invalid"
    assert record["code"] == "invalid_value"
    assert record["field"] == "vocabulary.terms"
    assert record["level"] == "error"
    assert set(record) <= {"event", "level", "timestamp", "code", "field"}
