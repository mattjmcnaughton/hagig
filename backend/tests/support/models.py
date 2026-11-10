"""Synthetic manifests, installations and a local HTTP fixture server.

Nothing here touches the network: the server listens on 127.0.0.1 and serves
synthetic bytes. Installations are written by hand (not by the installer), so
tests of the installer and of the checks derive their expectations
independently.
"""

import hashlib
import json
import os
import threading
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from hagig.manifest import Manifest, parse_manifest

REVISION = "a" * 40
WEIGHTS = b"synthetic safetensors weights " * 64
CONFIG = b'{"synthetic": true}\n'
FILES = {"config.json": CONFIG, "model.safetensors": WEIGHTS}

# A stand-in for convert.py: copies the source weights and config into the
# output directory, as the real tool writes config.json and weights.safetensors.
CONVERTER = b"""\
import pathlib, sys
args = dict(zip(sys.argv[1::2], sys.argv[2::2]))
src = pathlib.Path(args["--torch-name-or-path"])
out = pathlib.Path(args["--mlx-path"])
out.mkdir(parents=True, exist_ok=True)
mode = (src / "config.json").read_bytes()
if b"fail" in mode:
    sys.exit(3)
(out / "weights.safetensors").write_bytes(
    args["--dtype"].encode() + (src / "model.safetensors").read_bytes()
)
(out / "config.json").write_bytes(mode)
if b"extra" in mode:
    (out / "extra.bin").write_bytes(b"x")
"""


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


@dataclass
class Route:
    body: bytes = b""
    status: int = 200
    # Send only the first `truncate` bytes, then close (Content-Length stays).
    truncate: int | None = None
    location: str | None = None
    # None: the body's length. -1: no Content-Length; the body ends at close.
    content_length: int | None = None
    # When set, wait for it after the first `hold_after` bytes.
    hold: threading.Event | None = None
    hold_after: int = 0
    started: threading.Event = field(default_factory=threading.Event)


class FixtureServer:
    """A threaded HTTP/1.1 server on 127.0.0.1 with per-path routes."""

    def __init__(self) -> None:
        self.routes: dict[str, Route] = {}
        self.requests: list[str] = []
        routes, requests = self.routes, self.requests

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, format: str, *args: object) -> None:  # noqa: A002
                pass

            def do_GET(self) -> None:
                requests.append(self.path)
                route = routes.get(self.path)
                if route is None:
                    self.send_response(404)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                route.started.set()
                self.send_response(route.status)
                if route.location is not None:
                    self.send_header("Location", route.location)
                length = route.content_length
                if length == -1:
                    self.close_connection = True
                else:
                    size = len(route.body) if length is None else length
                    self.send_header("Content-Length", str(size))
                self.end_headers()
                body = route.body[: route.truncate]
                if route.hold is not None:
                    self.wfile.write(body[: route.hold_after])
                    self.wfile.flush()
                    route.hold.wait(30)
                    body = body[route.hold_after :]
                self.wfile.write(body)
                self.wfile.flush()
                if route.truncate is not None:
                    self.close_connection = True

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.httpd.daemon_threads = True
        self.base = f"http://127.0.0.1:{self.httpd.server_address[1]}"
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    def close(self) -> None:
        for route in self.routes.values():
            if route.hold is not None:
                route.hold.set()
        self.httpd.shutdown()
        self.httpd.server_close()


def manifest_bytes(
    base: str,
    files: dict[str, bytes] = FILES,
    *,
    model_id: str = "qwen3-asr-0.6b",
    converter: bytes | None = None,
    hashes: dict[str, str] | None = None,
    sizes: dict[str, int] | None = None,
    revision: str = REVISION,
) -> bytes:
    """A synthetic manifest whose files are served from `base`."""
    hashes, sizes = hashes or {}, sizes or {}
    document: dict = {
        "format": 1,
        "id": model_id,
        "engine": "mlx-whisper" if converter is not None else "qwen3-asr",
        "apple_silicon_only": converter is not None,
        "source": {
            "publisher": "Test",
            "repository": "test/model",
            "revision": revision,
            "license": "MIT",
            "license_url": f"{base}/license",
            "download": f"{base}/test/model/resolve/{revision}/",
        },
        "files": [
            {
                "path": name,
                "size": sizes.get(name, len(data)),
                "sha256": hashes.get(name, sha256(data)),
            }
            for name, data in sorted(files.items())
        ],
        "conversion": None,
    }
    if converter is not None:
        document["conversion"] = {
            "publisher": "Test",
            "repository": "test/tools",
            "commit": "b" * 40,
            "path": "convert.py",
            "license": "MIT",
            "license_url": f"{base}/license",
            "url": f"{base}/tools/convert.py",
            "size": sizes.get("convert.py", len(converter)),
            "sha256": hashes.get("convert.py", sha256(converter)),
            "arguments": ["--dtype", "float16"],
            "outputs": ["config.json", "weights.safetensors"],
        }
    return json.dumps(document).encode()


def synthetic_manifest(model_id: str) -> bytes:
    """A small manifest for the server tests; its files are `FILES`."""
    return manifest_bytes("http://127.0.0.1:9", model_id=model_id)


def serve(
    server: FixtureServer,
    files: dict[str, bytes] = FILES,
    *,
    converter: bytes | None = None,
    revision: str = REVISION,
) -> Manifest:
    """Route `files` (and the converter) on `server`; return their manifest."""
    for name, data in files.items():
        server.routes[f"/test/model/resolve/{revision}/{name}"] = Route(body=data)
    if converter is not None:
        server.routes["/tools/convert.py"] = Route(body=converter)
    model_id = "whisper-large-v3-turbo" if converter is not None else "qwen3-asr-0.6b"
    return parse_manifest(
        manifest_bytes(
            server.base,
            files,
            model_id=model_id,
            converter=converter,
            revision=revision,
        )
    )


def write_installation(
    models_root: Path, manifest: Manifest, files: dict[str, bytes], version: str
) -> Path:
    """Publish an installation by hand, as the layout in `hagig.models` says."""
    base = models_root / manifest.id
    target = base / version
    target.mkdir(parents=True)
    for name, data in files.items():
        (target / name).write_bytes(data)
    record = {
        "format": 1,
        "manifest": manifest.id,
        "manifest_sha256": manifest.digest,
        "files": [
            {"path": name, "size": len(data), "sha256": sha256(data)}
            for name, data in sorted(files.items())
        ],
    }
    (target / "hagig-install.json").write_text(json.dumps(record))
    link = base / "current"
    tmp = base / ".current-tmp"
    os.symlink(version, tmp)
    os.replace(tmp, link)
    return target
