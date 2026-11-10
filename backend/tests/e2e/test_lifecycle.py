"""Request lifecycle, cancellation and worker faults through the public API.

Covers TDD section 11's fake-worker list: results after cancellation, stale
generations, crashes while active, stalls to the deadline, upload disconnects,
stop, recovery on the next request and verified reaping.
"""

import os
import shutil
import signal
import struct
import sys
import time

import pytest

from tests.support.harness import (
    LAST_CHUNK,
    VOCABULARY,
    RawConnection,
    chunk,
    pid_alive,
    wait_for,
)

AUDIO = struct.pack("<4f", 0.0, 0.25, -1.0, 1.0)


def open_upload(home, request_id, first=AUDIO):
    connection = RawConnection(home.socket)
    connection.send(
        f"PUT /v1/requests/{request_id}/audio HTTP/1.1\r\nHost: localhost\r\n"
        "Content-Type: application/octet-stream\r\n"
        "Transfer-Encoding: chunked\r\n\r\n".encode()
        + chunk(first)
    )
    return connection


def start_computing(home, request_id):
    connection = open_upload(home, request_id)
    connection.send(LAST_CHUNK)
    return connection, wait_for(home.computing)[0]


def code(response):
    return response.status_code, response.json()


def assert_recovers(home, previous_pids):
    """The slot is free, and the next request succeeds on a fresh worker."""
    home.engine()
    response = home.transcribe(AUDIO)
    assert code(response) == (200, {"text": "Fixture."})
    new = home.pids()[-1]
    assert new not in previous_pids
    for pid in previous_pids:
        assert not pid_alive(pid)


def test_warm_worker_serves_consecutive_requests(server):
    for text in ["one", "two"]:
        server.engine(text=text)
        assert code(server.transcribe(AUDIO)) == (200, {"text": text})
    assert len(server.pids()) == 1
    assert server.status()["worker"] == "running"


def test_result_after_cancellation_is_discarded(server):
    # The engine finishes after the DELETE and ignores SIGTERM, so its result
    # really is written after invalidation, before the exit request lands.
    server.engine(behavior="delay", delay=0.4, ignore_term=True)
    request_id = server.admit()
    connection, pid = start_computing(server, request_id)
    with server.client() as client:
        assert client.delete(f"/v1/requests/{request_id}").status_code == 204
    status, _headers, body = connection.response()
    assert (status, body) == (409, b'{"code":"cancelled"}')
    # The response comes only after the worker is reaped and the slot released.
    assert not pid_alive(pid)
    assert server.status()["state"] == "idle"
    assert_recovers(server, [pid])


@pytest.mark.parametrize(
    "tamper", ["wrong_generation", "wrong_request_id", "bad_ready"]
)
def test_mismatched_replies_retire_the_worker(server, tamper):
    server.engine(tamper=tamper)
    assert code(server.transcribe(AUDIO)) == (500, {"code": "worker_failed"})
    pid = server.pids()[-1]
    assert not pid_alive(pid)
    assert_recovers(server, [pid])


def test_stale_generation_cannot_match_the_next_worker(server):
    # Generation 1 serves a request, then retires; generation 2 answers with
    # generation 1, which can never match its request.
    assert server.transcribe(AUDIO).status_code == 200
    server.engine(behavior="crash")
    assert server.transcribe(AUDIO).status_code == 500
    server.engine(tamper="stale_generation")
    assert code(server.transcribe(AUDIO)) == (500, {"code": "worker_failed"})


def test_stray_byte_while_idle_retires_the_worker(server):
    server.engine(tamper="stray_after_result")
    assert server.transcribe(AUDIO).status_code == 200
    pid = server.pids()[-1]
    wait_for(lambda: server.status()["worker"] == "absent")
    assert not pid_alive(pid)
    assert_recovers(server, [pid])


def test_crash_while_active_fails_only_that_request(server):
    assert server.transcribe(AUDIO).status_code == 200
    warm = server.pids()[-1]
    server.engine(behavior="crash")
    assert code(server.transcribe(AUDIO)) == (500, {"code": "worker_failed"})
    # No automatic retry: the crashed request launched nothing else.
    assert server.pids() == [warm]
    assert_recovers(server, [warm])


def test_stall_hits_the_computation_deadline_and_escalates_to_kill(home):
    home.write_config()
    home.install_model()
    home.start_server(deadlines={"computation": 0.3})
    home.engine(behavior="stall", ignore_term=True)
    started = time.monotonic()
    response = home.transcribe(AUDIO)
    elapsed = time.monotonic() - started
    assert code(response) == (504, {"code": "deadline_exceeded"})
    pid = home.pids()[-1]
    assert not pid_alive(pid)
    # Exit request, 1 s, SIGTERM (ignored), 1 s, SIGKILL.
    assert 2.3 <= elapsed < 6
    assert_recovers(home, [pid])


def test_disconnect_during_upload_cancels_at_once(server):
    request_id = server.admit()
    connection = open_upload(server, request_id)
    wait_for(lambda: server.status()["state"] == "busy")
    connection.close()
    server.wait_idle(timeout=2)
    # The request never reached a worker.
    assert server.pids() == []
    assert_recovers(server, [])


def test_disconnect_while_computing_kills_the_worker(server):
    server.engine(behavior="stall")
    request_id = server.admit()
    connection, pid = start_computing(server, request_id)
    connection.close()
    wait_for(lambda: not pid_alive(pid), timeout=5)
    server.wait_idle(timeout=2)
    assert_recovers(server, [pid])


def test_closing_another_connection_cancels_nothing(server):
    server.engine(behavior="delay", delay=0.3)
    request_id = server.admit()
    with server.client() as other:
        other.get("/v1/status")
    connection = open_upload(server, request_id)
    with server.client() as other:
        other.post("/v1/requests")
    connection.send(LAST_CHUNK)
    assert connection.response()[0] == 200


def test_busy_never_disturbs_the_active_request(server):
    request_id = server.admit()
    with server.client() as client:
        assert code(client.post("/v1/requests")) == (409, {"code": "busy"})
    connection = open_upload(server, request_id)
    with server.client() as client:
        assert code(client.post("/v1/requests")) == (409, {"code": "busy"})
        # A DELETE for another ID is acknowledged and changes nothing.
        assert client.delete("/v1/requests/other-id").status_code == 204
    connection.send(LAST_CHUNK)
    status, _headers, body = connection.response()
    assert (status, body) == (200, b'{"text":"Fixture."}')


def test_upload_start_deadline_releases_the_slot(home):
    home.write_config()
    home.install_model()
    home.start_server(deadlines={"upload_start": 0.3})
    request_id = home.admit()
    home.wait_idle(timeout=2)
    assert home.upload(request_id, AUDIO).status_code == 404
    assert home.transcribe(AUDIO).status_code == 200


def test_cancel_before_upload_frees_the_slot_immediately(server):
    request_id = server.admit()
    with server.client() as client:
        assert client.delete(f"/v1/requests/{request_id}").status_code == 204
    assert server.status()["state"] == "idle"
    assert server.upload(request_id, AUDIO).status_code == 404


def test_delete_while_computing_keeps_admission_busy_until_reaped(server):
    server.engine(behavior="stall", ignore_term=True)
    request_id = server.admit()
    connection, pid = start_computing(server, request_id)
    with server.client() as client:
        assert client.delete(f"/v1/requests/{request_id}").status_code == 204
        # The worker ignores SIGTERM, so reaping takes about 2 s.
        assert code(client.post("/v1/requests")) == (409, {"code": "busy"})
    assert connection.response()[0] == 409
    assert not pid_alive(pid)
    assert server.status()["state"] == "idle"


def test_stop_during_computation_answers_reaps_and_exits(server):
    server.engine(behavior="stall")
    process = server.servers[-1]
    request_id = server.admit()
    connection, pid = start_computing(server, request_id)
    with server.client() as client:
        assert client.post("/v1/stop").status_code == 202
    status, _headers, body = connection.response()
    assert (status, body) == (503, b'{"code":"server_stopping"}')
    assert process.wait(timeout=10) == 0
    assert not pid_alive(pid)
    assert not server.socket.exists()


def test_stop_reaps_a_warm_worker_and_releases_the_lock(server):
    from hagig.paths import ServerLock

    assert server.transcribe(AUDIO).status_code == 200
    pid = server.pids()[-1]
    with server.client() as client:
        assert client.post("/v1/stop").status_code == 202
    assert server.servers[-1].wait(timeout=10) == 0
    assert not pid_alive(pid)
    assert not server.socket.exists()
    lock = ServerLock.acquire(server.runtime)
    assert lock is not None
    lock.release()


def test_stopping_state_answers_until_the_socket_is_removed(home):
    home.write_config()
    home.install_model()
    hold = home.root / "release"
    process = home.start_server(hold_file=str(hold))
    with home.client() as client:
        assert client.post("/v1/stop").status_code == 202
        assert code(client.get("/v1/status")) == (503, {"code": "server_stopping"})
        assert client.post("/v1/stop").status_code == 202
        assert client.delete("/v1/requests/x").status_code == 204
    hold.touch()
    assert process.wait(timeout=10) == 0
    assert not home.socket.exists()


def test_signal_shutdown_reaps_the_worker(server):
    assert server.transcribe(AUDIO).status_code == 200
    pid = server.pids()[-1]
    process = server.servers[-1]
    process.send_signal(signal.SIGTERM)
    process.wait(timeout=10)
    assert not pid_alive(pid)


def test_launch_hygiene(server):
    assert server.transcribe(AUDIO).status_code == 200
    pid = server.pids()[-1]
    launch = server.record("launch", pid)
    # Python's locale coercion may add LC_CTYPE, and macOS adds
    # __CF_USER_TEXT_ENCODING to every process; neither comes from the server.
    added = {"LC_CTYPE", "__CF_USER_TEXT_ENCODING"}
    assert set(launch["env"]) - added == {
        "HOME",
        "PATH",
        "HF_HUB_OFFLINE",
        "TRANSFORMERS_OFFLINE",
        "HF_HUB_DISABLE_TELEMETRY",
        "DO_NOT_TRACK",
    }
    assert launch["cwd"] == "/"
    assert launch["fds"] == []
    # Disabled mode is not sandboxed (the Seatbelt test's negative control).
    assert launch["sandboxed"] == (0 if sys.platform == "darwin" else None)
    # Vocabulary travels only in `load`.
    exposed = " ".join([*launch["argv"], *launch["env_values"].values()])
    for term in VOCABULARY:
        assert term not in exposed
    assert server.record("vocabulary", pid) == VOCABULARY
    # The resolved, immutable version, never the swappable `current` link.
    assert server.record("load", pid)["model_dir"] == str(
        server.models / "qwen3-asr-0.6b" / ("v-" + "0" * 32)
    )


def test_diagnostics_are_content_free(server):
    server.engine(text="secret transcript words")
    assert server.transcribe(AUDIO).status_code == 200
    server.engine(behavior="crash")
    server.transcribe(AUDIO)
    with server.client() as client:
        client.post("/v1/stop")
    server.servers[-1].wait(timeout=10)
    logs = server.server_logs()
    assert b"worker_launched" in logs
    for secret in [b"secret transcript", *(t.encode() for t in VOCABULARY), b"/tmp"]:
        assert secret not in logs


def test_required_mode_on_linux_refuses_without_launching(home):
    home.write_config(isolation="required")
    home.install_model()
    home.start_server(platform="linux")
    assert home.status()["network_isolation"] == "required"
    response = home.transcribe(AUDIO)
    assert code(response) == (503, {"code": "isolation_unavailable"})
    assert home.pids() == []
    # Required mode never falls back: the next request is refused the same way.
    assert code(home.transcribe(AUDIO))[1] == {"code": "isolation_unavailable"}


def test_model_missing_is_checked_before_isolation_and_launch(home):
    home.write_config(isolation="required")
    home.start_server(platform="linux")
    assert code(home.transcribe(AUDIO)) == (503, {"code": "model_missing"})
    assert home.pids() == []


def test_isolation_is_checked_before_the_installation_contents(home):
    home.write_config(isolation="required")
    version = home.install_model()
    (version / "config.json").unlink()
    home.start_server(platform="linux")
    assert code(home.transcribe(AUDIO)) == (503, {"code": "isolation_unavailable"})
    assert home.pids() == []


@pytest.mark.parametrize("damage", ["extra_file", "short_file", "record"])
def test_the_server_refuses_an_invalid_installation_before_launch(home, damage):
    home.write_config()
    version = home.install_model()
    if damage == "extra_file":
        (version / "pytorch_model.bin").write_bytes(b"pickle")
    elif damage == "short_file":
        weights = version / "model.safetensors"
        weights.write_bytes(weights.read_bytes()[:-1])
    else:
        (version / "hagig-install.json").write_text("{}")
    home.start_server()
    assert code(home.transcribe(AUDIO)) == (503, {"code": "model_invalid"})
    assert home.pids() == []


def test_a_same_size_corruption_is_caught_by_the_worker_at_load(home):
    home.write_config()
    home.install_model(corrupt=True)
    home.start_server()
    assert code(home.transcribe(AUDIO)) == (503, {"code": "model_invalid"})
    # The worker launched, hashed the files and refused before any engine load.
    pid = home.pids()[-1]
    assert not (home.control / f"load-{pid}.json").exists()


def test_a_new_install_never_changes_a_warm_workers_model(home):
    home.write_config()
    first = home.install_model()
    home.start_server()
    assert code(home.transcribe(AUDIO))[0] == 200
    warm = home.pids()[-1]

    # Publish another version and remove the first, as the installer does.
    second = home.install_model(version="1" * 32)
    shutil.rmtree(first)
    assert code(home.transcribe(AUDIO))[0] == 200
    assert home.pids() == [warm]
    assert home.record("load", warm)["model_dir"] == str(first)

    # Only a newly launched worker loads the new version.
    home.engine(behavior="crash")
    assert code(home.transcribe(AUDIO)) == (500, {"code": "worker_failed"})
    home.engine()
    assert code(home.transcribe(AUDIO))[0] == 200
    assert home.record("load", home.pids()[-1])["model_dir"] == str(second)


@pytest.mark.skipif(sys.platform != "darwin", reason="Seatbelt is macOS only")
def test_required_mode_runs_the_worker_under_seatbelt(home):
    """The worker starts and speaks over its pipes under seatbelt-v1.sb.

    Launch and pipe-IPC evidence only; not network-denial evidence (#49).
    """
    home.write_config(isolation="required")
    home.install_model()
    home.start_server()
    response = home.transcribe(AUDIO)
    assert code(response) == (200, {"text": "Fixture."})
    launch = home.record("launch", home.pids()[-1])
    assert launch["sandboxed"]


def test_worker_argv_in_required_mode_on_macos_uses_sandbox_exec(tmp_path):
    from hagig.launcher import SEATBELT_PROFILE, Launcher

    fake_exec = tmp_path / "sandbox-exec"
    fake_exec.touch(mode=0o755)
    launcher = Launcher(
        command=("py", "-m", "w"), platform="darwin", sandbox_exec=fake_exec
    )
    assert launcher.argv("required") == [
        str(fake_exec),
        "-f",
        str(SEATBELT_PROFILE),
        "py",
        "-m",
        "w",
    ]
    assert SEATBELT_PROFILE.is_absolute() and SEATBELT_PROFILE.is_file()
    assert launcher.argv("disabled") == ["py", "-m", "w"]
    assert (
        Launcher(platform="darwin", sandbox_exec=tmp_path / "missing").argv("required")
        is None
    )
    assert Launcher(platform="linux").argv("required") is None
    assert os.access(fake_exec, os.X_OK)


def test_reservation_deadline_ends_with_the_body(home):
    # A short reservation must not cut into the separate computation deadline.
    home.write_config()
    home.install_model()
    home.start_server(deadlines={"reservation": 0.3})
    home.engine(behavior="delay", delay=0.8)
    assert code(home.transcribe(AUDIO)) == (200, {"text": "Fixture."})


def stub_sandbox_exec(home):
    """A stand-in for macOS sandbox-exec that runs the command unsandboxed."""
    path = home.root / "sandbox-exec"
    path.write_text('#!/bin/sh\nshift 2\nexec "$@"\n')
    path.chmod(0o755)
    return str(path)


@pytest.mark.parametrize("tamper", ["exit_before_ready", "partial_ready"])
@pytest.mark.parametrize(
    ("isolation", "expected"),
    [("required", "isolation_unavailable"), ("disabled", "worker_failed")],
)
def test_exit_before_the_ready_line_fails_closed(home, tamper, isolation, expected):
    home.write_config(isolation=isolation)
    home.install_model()
    home.start_server(platform="darwin", sandbox_exec=stub_sandbox_exec(home))
    home.engine(tamper=tamper)
    assert code(home.transcribe(AUDIO)) == (
        500 if expected == "worker_failed" else 503,
        {"code": expected},
    )
    assert len(home.pids()) == 1
    # The stub really ran the worker in required mode, and nothing fell back.
    home.engine()
    expect_ok = code(home.transcribe(AUDIO))
    assert expect_ok == (200, {"text": "Fixture."})


@pytest.mark.parametrize(
    "request_line",
    [
        "GET /v1/status%0A HTTP/1.1",
        "POST /v1/stop%0A HTTP/1.1",
        "POST /v1/requests%0A HTTP/1.1",
        "GET /v1/status%00 HTTP/1.1",
    ],
)
def test_control_characters_after_a_path_are_unknown_routes(server, request_line):
    connection = RawConnection(server.socket)
    connection.send(
        f"{request_line}\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n".encode()
    )
    status, _headers, body = connection.response()
    connection.close()
    assert (status, body) == (400, b'{"code":"invalid_request"}')
    # Nothing was stopped or admitted.
    assert server.status()["state"] == "idle"
