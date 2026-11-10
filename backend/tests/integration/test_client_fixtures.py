"""The CLI's client against a peer that serves the shared fixtures' bytes exactly.

PROTOCOL.md, Shared fixtures: the peer checks method, target, Content-Type and
the CLI's `Content-Length` framing, then sends the fixture response verbatim.
"""

import json
import os
import socket
import subprocess
import sys
import threading
from pathlib import Path

import pytest

from hagig.client import Client
from tests.support.harness import short_runtime_base

FIXTURES = json.loads(
    (Path(__file__).parents[1] / "fixtures" / "rest-v1-fixtures.json").read_text()
)
BY_NAME = {e["name"]: e for e in FIXTURES["exchanges"]}
CLIENT_EXCHANGES = [e for e in FIXTURES["exchanges"] if "client" in e["consumers"]]
HAGIG = str(Path(sys.executable).parent / "hagig")


def response_bytes(exchange):
    response = exchange["response"]
    head = f"HTTP/1.1 {response['status']} {response['reason']}\r\n"
    head += "".join(f"{name}: {value}\r\n" for name, value in response["headers"])
    body = response["body"]
    return (head + "\r\n").encode() + bytes.fromhex(body.get("hex", ""))


class Peer:
    """Serves one fixture response per connection, in order, on a Unix socket."""

    def __init__(self, path, exchanges):
        self.exchanges = list(exchanges)
        self.requests = []
        self.errors = []
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(os.fsencode(path))
        self.listener.listen(8)
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def _serve(self):
        for exchange in self.exchanges:
            connection, _ = self.listener.accept()
            with connection:
                try:
                    self._answer(connection, exchange)
                except Exception as error:  # reported by the test
                    self.errors.append(repr(error))

    def _answer(self, connection, exchange):
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = connection.recv(65536)
            if not chunk:
                raise AssertionError("closed before the request head")
            data += chunk
        head, _, body = data.partition(b"\r\n\r\n")
        lines = head.decode("latin-1").split("\r\n")
        method, target, _version = lines[0].split(" ")
        headers = {}
        for line in lines[1:]:
            name, _, value = line.partition(":")
            headers[name.strip().lower()] = value.strip()
        self.requests.append((method, target))
        request = exchange["request"]
        assert (method, target) == (request["method"], request["target"])
        if method == "PUT":
            # The CLI's framing: one Content-Length body, never chunked.
            assert headers.get("content-type") == "application/octet-stream"
            assert "transfer-encoding" not in headers
            length = int(headers["content-length"])
            if not request["body"].get("open"):
                while len(body) < length:
                    body += connection.recv(65536)
        connection.sendall(response_bytes(exchange))

    def close(self):
        self.listener.close()


@pytest.fixture
def runtime():
    with short_runtime_base() as base:
        yield base


def call(client, exchange):
    method = exchange["request"]["method"]
    target = exchange["request"]["target"]
    request_id = target.split("/")[3] if target.count("/") >= 3 else ""
    if target == "/v1/status":
        return client.status()
    if method == "POST" and target == "/v1/requests":
        return client.admit()
    if method == "PUT":
        return client.upload(request_id, bytes(12))
    if method == "DELETE":
        return client.cancel(request_id)
    return client.stop()


@pytest.mark.parametrize("exchange", CLIENT_EXCHANGES, ids=lambda e: e["name"])
def test_client_outcome(exchange, runtime):
    path = runtime / "peer.sock"
    peer = Peer(path, [exchange])
    try:
        with Client(path) as client:
            outcome = call(client, exchange)
        peer.thread.join(timeout=10)
    finally:
        peer.close()
    assert peer.errors == []
    expected = exchange["client"]
    if expected.get("then") == "cancel_admitted":
        # The client layer admits; the CLI's admission rule, tested below,
        # turns a changed generation into a generic failure and a DELETE.
        assert outcome.kind == "admitted"
        return
    assert outcome.kind == expected["outcome"]
    assert outcome.code == expected.get("code")
    if expected["outcome"] == "text":
        assert outcome.text == expected["text"]


def test_cli_cancels_an_admission_from_a_restarted_server(runtime, tmp_path):
    (runtime / "hagig").mkdir(mode=0o700)
    exchanges = [
        BY_NAME["status_idle"],
        BY_NAME["admit_config_changed"],
        BY_NAME["cancel_reserved"],
    ]
    peer = Peer(runtime / "hagig" / "server.sock", exchanges)
    env = {
        "HOME": str(tmp_path),
        "XDG_RUNTIME_DIR": str(runtime),
        "XDG_CONFIG_HOME": str(tmp_path / "config"),
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
    }
    try:
        result = subprocess.run(
            [HAGIG, "transcribe", str(tmp_path / "never-read.wav")],
            env=env,
            capture_output=True,
            timeout=30,
        )
        peer.thread.join(timeout=10)
    finally:
        peer.close()
    assert peer.errors == []
    assert (result.returncode, result.stdout, result.stderr) == (
        1,
        b"",
        b"generic_failure\n",
    )
    assert peer.requests == [
        ("GET", "/v1/status"),
        ("POST", "/v1/requests"),
        ("DELETE", "/v1/requests/fixture-request-1"),
    ]


def test_cli_reports_incompatible_api_and_does_not_admit(runtime, tmp_path):
    (runtime / "hagig").mkdir(mode=0o700)
    incompatible = BY_NAME["status_api_version_2"]
    peer = Peer(runtime / "hagig" / "server.sock", [incompatible, incompatible])
    env = {
        "HOME": str(tmp_path),
        "XDG_RUNTIME_DIR": str(runtime),
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
    }
    try:
        for command in (["transcribe", str(tmp_path / "x.wav")], ["stop"]):
            result = subprocess.run(
                [HAGIG, *command], env=env, capture_output=True, timeout=30
            )
            assert (result.returncode, result.stderr) == (1, b"incompatible_api\n")
        peer.thread.join(timeout=10)
    finally:
        peer.close()
    assert peer.errors == []
    # Neither command admitted, stopped or restarted anything.
    assert peer.requests == [("GET", "/v1/status"), ("GET", "/v1/status")]
