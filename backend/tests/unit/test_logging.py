import json
import os
import shutil
import stat

import pytest
import structlog

from hagig.logging import LogFile, configure_logging

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


def lines(path):
    return [json.loads(line) for line in path.read_text().splitlines()]


@pytest.mark.usefixtures("restore_structlog")
def test_the_log_file_gets_the_same_filtered_lines_in_a_private_file(tmp_path, capsys):
    path = tmp_path / "server.log"
    log_file = LogFile.open(path)
    assert log_file is not None
    configure_logging(log_file)
    structlog.get_logger().info(
        "request_completed", duration_ms=12, text=SENTINEL, stage="speech"
    )
    assert stat.S_IMODE(os.lstat(path).st_mode) == 0o600
    assert SENTINEL not in path.read_text()
    [record] = lines(path)
    assert record["event"] == "request_completed"
    assert set(record) == {"event", "level", "timestamp", "duration_ms", "stage"}
    # stderr carries the same line.
    assert json.loads(capsys.readouterr().err) == record


def test_the_log_file_rotates_at_its_bound_keeping_one_previous_file(tmp_path):
    path = tmp_path / "server.log"
    log_file = LogFile.open(path, max_bytes=100)
    assert log_file is not None
    line = "x" * 39  # 40 bytes with the newline
    for index in range(5):
        log_file.write(f"{index}{line[1:]}")
    previous = tmp_path / "server.log.1"
    # 0 and 1 filled the first file; 2 and 3 the second, now previous; 4 is new.
    assert path.read_text() == f"4{line[1:]}\n"
    assert previous.read_text() == f"2{line[1:]}\n3{line[1:]}\n"
    assert sorted(p.name for p in tmp_path.iterdir()) == ["server.log", "server.log.1"]
    assert stat.S_IMODE(os.lstat(path).st_mode) == 0o600
    assert all(p.stat().st_size <= 100 for p in tmp_path.iterdir())


def test_an_unsafe_log_file_is_refused_untouched(tmp_path):
    target = tmp_path / "target"
    target.write_text("keep")
    link = tmp_path / "server.log"
    link.symlink_to(target)
    assert LogFile.open(link) is None
    loose = tmp_path / "loose.log"
    loose.write_text("keep")
    loose.chmod(0o644)
    assert LogFile.open(loose) is None
    fifo = tmp_path / "fifo.log"
    os.mkfifo(fifo, 0o600)
    assert LogFile.open(fifo) is None
    assert target.read_text() == "keep" and loose.read_text() == "keep"
    assert LogFile.open(tmp_path / "missing" / "server.log") is None


@pytest.mark.usefixtures("restore_structlog")
def test_a_log_file_that_fails_mid_run_is_dropped_silently(tmp_path, capsys):
    logs = tmp_path / "logs"
    logs.mkdir()
    log_file = LogFile.open(logs / "server.log", max_bytes=150)
    assert log_file is not None
    configure_logging(log_file)
    log = structlog.get_logger()
    log.info("server_started")
    # Rotation cannot reopen once the directory is gone (as after uninstall).
    shutil.rmtree(logs)
    log.info("worker_launched", version=1)
    log.info("server_stopped")
    assert not logs.exists()
    assert [
        json.loads(line)["event"] for line in capsys.readouterr().err.splitlines()
    ] == [
        "server_started",
        "worker_launched",
        "server_stopped",
    ]
