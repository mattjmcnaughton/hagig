"""Test-only worker: the real `hagig.worker.main` with a probe engine.

Launched as `python -I probe_worker.py '<json>'`, through the production
`Launcher.argv`, so in required mode it runs exactly as the real worker does:
`sandbox-exec -f seatbelt-v1.sb` first. Never reachable from the package,
configuration, the CLI or the environment.

`load` does nothing. `transcribe` attempts networking and the GPU paths from
inside the worker process and returns the observations as JSON text, so a
result arriving at all shows that pipe IPC works. The JSON argument names the
loopback listener ports the test opened outside the sandbox.
"""

import errno
import json
import os
import socket
import sys

ARGS = json.loads(sys.argv[1])
EXTERNAL_V4 = ("1.1.1.1", 443)
EXTERNAL_V6 = ("2606:4700:4700::1111", 443, 0, 0)
DNS_NAME = "example.com"


def _error(error: OSError) -> str:
    return errno.errorcode.get(error.errno or 0, str(error.errno))


def _tcp(family: int, address: tuple) -> str:
    with socket.socket(family, socket.SOCK_STREAM) as sock:
        sock.settimeout(5)
        try:
            sock.connect(address)
        except OSError as error:
            return _error(error)
    return "connected"


def _udp() -> str:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        try:
            sock.sendto(b"\0" * 12, ("8.8.8.8", 53))
        except OSError as error:
            return _error(error)
    return "sent"


def _dns() -> str:
    try:
        socket.getaddrinfo(DNS_NAME, 443)
    except socket.gaierror as error:
        return f"gaierror:{error.errno}"
    except OSError as error:
        return _error(error)
    return "resolved"


def _sandboxed() -> int:
    import ctypes

    check = ctypes.CDLL(None).sandbox_check
    check.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
    check.restype = ctypes.c_int
    return check(os.getpid(), None, 0)


def _mps() -> dict:
    try:
        import torch
    except ImportError:
        return {"installed": False}
    found = {"installed": True, "available": torch.backends.mps.is_available()}
    try:
        value = (torch.arange(4.0, device="mps") * 2).sum().item()
        found["computed"] = value == 12.0
    except Exception as error:  # noqa: BLE001 - recorded, not raised
        found["computed"] = type(error).__name__
    return found


def _metal() -> dict:
    try:
        import mlx.core as mx
    except ImportError:
        return {"installed": False}
    found = {
        "installed": True,
        "available": mx.metal.is_available(),
        "device": str(mx.default_device()),
    }
    try:
        ones = mx.ones((64, 64), stream=mx.gpu)
        found["computed"] = float(mx.sum(ones @ ones, stream=mx.gpu)) == 64.0**3
    except Exception as error:  # noqa: BLE001 - recorded, not raised
        found["computed"] = type(error).__name__
    return found


class Probe:
    def load(self, model_dir) -> None:
        pass

    def transcribe(self, audio, vocabulary) -> str:
        return json.dumps(
            {
                "sandboxed": _sandboxed(),
                "loopback_v4": _tcp(socket.AF_INET, ("127.0.0.1", ARGS["v4"])),
                "loopback_v6": _tcp(socket.AF_INET6, ("::1", ARGS["v6"], 0, 0)),
                "external_v4": _tcp(socket.AF_INET, EXTERNAL_V4),
                "external_v6": _tcp(socket.AF_INET6, EXTERNAL_V6),
                "udp_dns_v4": _udp(),
                "dns": _dns(),
                "mps": _mps(),
                "metal": _metal(),
            },
            sort_keys=True,
        )


from hagig.worker import main  # noqa: E402

main({"qwen3-asr": Probe, "mlx-whisper": Probe})
