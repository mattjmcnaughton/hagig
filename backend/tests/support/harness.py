"""Shared helpers for server and CLI tests over the real Unix socket."""

import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
from contextlib import contextmanager
from pathlib import Path

import httpx

SUPPORT = Path(__file__).resolve().parent
SERVE_FAKE = SUPPORT / "serve_fake.py"
MODEL_ID = "qwen3-asr-0.6b"
TOKEN = re.compile(r"[A-Za-z0-9_-]{1,128}")
VOCABULARY = ["Hagig", "Ghostty-secret-term"]


def wait_for(predicate, timeout=10.0, interval=0.01):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        value = predicate()
        if value:
            return value
        time.sleep(interval)
    raise AssertionError("condition not reached")


def pid_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


@contextmanager
def short_runtime_base():
    """An owner-only XDG_RUNTIME_DIR short enough for sun_path on macOS."""
    base = tempfile.mkdtemp(prefix="hg", dir="/tmp")
    os.chmod(base, 0o700)
    try:
        yield Path(base)
    finally:
        shutil.rmtree(base, ignore_errors=True)


class Home:
    """An isolated user: XDG directories, config, models and fake control."""

    def __init__(self, root: Path, runtime_base: Path) -> None:
        self.root = root
        self.env = {
            "HOME": str(root / "home"),
            "XDG_CONFIG_HOME": str(root / "config"),
            "XDG_DATA_HOME": str(root / "data"),
            "XDG_RUNTIME_DIR": str(runtime_base),
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        }
        (root / "home").mkdir()
        self.config_path = root / "config" / "hagig" / "config.toml"
        self.models = root / "data" / "hagig" / "models"
        self.control = root / "control"
        self.control.mkdir()
        self.runtime = runtime_base / "hagig"
        self.socket = self.runtime / "server.sock"
        self.servers: list[subprocess.Popen] = []

    def write_config(self, isolation="disabled", model_id=MODEL_ID, terms=VOCABULARY):
        self.config_path.parent.mkdir(parents=True, exist_ok=True)
        self.config_path.write_text(
            f'[model]\nid = "{model_id}"\n'
            f'[inference]\nnetwork_isolation = "{isolation}"\n'
            f"[vocabulary]\nterms = {json.dumps(terms)}\n"
        )

    def install_model(self, model_id=MODEL_ID, corrupt=False):
        path = self.models / model_id
        path.mkdir(parents=True, exist_ok=True)
        if corrupt:
            (path / "CORRUPT").touch()

    def engine(self, **control):
        (self.control / "control.json").write_text(json.dumps(control))

    # Records written by the fake worker.

    def pids(self):
        try:
            return [int(p) for p in (self.control / "pids").read_text().split()]
        except FileNotFoundError:
            return []

    def record(self, name, pid, suffix=".json"):
        data = (self.control / f"{name}-{pid}{suffix}").read_bytes()
        return json.loads(data) if suffix == ".json" else data

    def computing(self):
        return [p for p in self.pids() if (self.control / f"computing-{p}").exists()]

    # Server processes.

    def start_server(self, *, wait=True, **options):
        options.setdefault("control_dir", str(self.control))
        log = self.root / f"server-{len(self.servers)}.log"
        with open(log, "wb") as stderr:
            process = subprocess.Popen(
                [sys.executable, "-I", str(SERVE_FAKE), json.dumps(options)],
                env=self.env,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=stderr,
                start_new_session=True,
            )
        self.servers.append(process)
        if wait:
            wait_for(self.ready, timeout=15)
        return process

    def server_logs(self):
        return b"".join(p.read_bytes() for p in sorted(self.root.glob("server-*.log")))

    def ready(self):
        try:
            with self.client() as client:
                return client.get("/v1/status").status_code == 200
        except httpx.TransportError:
            return False

    def client(self, timeout=10.0):
        return httpx.Client(
            transport=httpx.HTTPTransport(uds=str(self.socket)),
            base_url="http://localhost",
            timeout=timeout,
        )

    def status(self):
        with self.client() as client:
            return client.get("/v1/status").json()

    def admit(self):
        with self.client() as client:
            response = client.post("/v1/requests")
        assert response.status_code == 201, response.content
        return response.json()["request_id"]

    def upload(self, request_id, audio, timeout=30.0):
        with self.client(timeout=timeout) as client:
            return client.put(
                f"/v1/requests/{request_id}/audio",
                content=audio,
                headers={"content-type": "application/octet-stream"},
            )

    def transcribe(self, audio):
        return self.upload(self.admit(), audio)

    def wait_idle(self, timeout=10.0):
        wait_for(lambda: self.status()["state"] == "idle", timeout=timeout)

    def cleanup(self):
        for process in self.servers:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
        for pid in self.pids():
            if pid_alive(pid):
                os.kill(pid, signal.SIGKILL)


class RawConnection:
    """One HTTP/1.1 exchange written byte for byte on the Unix socket."""

    def __init__(self, path: Path) -> None:
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(30)
        self.sock.connect(os.fsencode(path))

    def send(self, data: bytes) -> bool:
        """Send, returning False if the server already closed the connection."""
        try:
            self.sock.sendall(data)
        except (BrokenPipeError, ConnectionResetError):
            return False
        return True

    def response(self):
        """Read one response: (status, [(name, value)], body, closed_after)."""
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise AssertionError("connection closed before a response head")
            data += chunk
        head, _, body = data.partition(b"\r\n\r\n")
        lines = head.decode("latin-1").split("\r\n")
        status = int(lines[0].split()[1])
        headers = [
            tuple(part.strip() for part in line.split(":", 1)) for line in lines[1:]
        ]
        length = int(dict((n.lower(), v) for n, v in headers).get("content-length", 0))
        while len(body) < length:
            chunk = self.sock.recv(65536)
            if not chunk:
                break
            body += chunk
        return status, headers, body[:length]

    def closed_by_peer(self, timeout=5.0):
        self.sock.settimeout(timeout)
        try:
            return self.sock.recv(1) == b""
        except ConnectionResetError:
            return True

    def close(self):
        self.sock.close()


def chunk(data: bytes) -> bytes:
    return b"%x\r\n" % len(data) + data + b"\r\n"


LAST_CHUNK = b"0\r\n\r\n"
