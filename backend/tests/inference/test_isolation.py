"""Network denial and GPU access inside the real worker process (#49).

Opt-in: see conftest.py. The test-only probe worker (`tests/support/
probe_worker.py`) is the real `hagig.worker.main` with a probe engine, launched
through the production `Launcher.argv` and `worker_env` and spoken to by the
real `Supervisor` over its pipes. Required mode runs it under the real
`seatbelt-v1.sb`; the disabled-mode run in the same job is the unsandboxed
connectivity control. The loopback listeners belong to this (unsandboxed)
test process, so the IPv4 and IPv6 controls do not depend on the runner's
external routes. A result arriving at all shows that pipe IPC works.
"""

import asyncio
import json
import os
import socket
import struct
import sys
from contextlib import ExitStack

import pytest

from hagig.launcher import SEATBELT_PROFILE, Launcher, worker_env
from hagig.manifest import parse_manifest
from hagig.services.supervisor import Supervisor, WorkerSettings
from tests.inference.stack import dns_lookups, log_mark, record
from tests.support.harness import SUPPORT
from tests.support.models import FILES, synthetic_manifest, write_installation

AUDIO = struct.pack("<2f", 0.0, 0.5)
DENIED = "EPERM"


def listen(family, host, stack):
    sock = stack.enter_context(socket.socket(family, socket.SOCK_STREAM))
    sock.bind((host, 0))
    sock.listen(8)
    return sock.getsockname()[1]


def probe(tmp_path, mode, ports, prefix=()):
    models = tmp_path / f"models-{mode}-{len(prefix)}"
    manifest = parse_manifest(synthetic_manifest("qwen3-asr-0.6b"))
    write_installation(models, manifest, FILES, "v-" + "0" * 32)
    command = (
        *prefix,
        sys.executable,
        "-I",
        str(SUPPORT / "probe_worker.py"),
        json.dumps(ports),
    )
    settings = WorkerSettings(
        launcher=Launcher(command=command),
        mode=mode,
        env=worker_env(os.environ),
        models_root=models,
        manifest=manifest,
        vocabulary=(),
    )

    async def run():
        supervisor = Supervisor(settings)
        try:
            return await supervisor.transcribe("probe", AUDIO)
        finally:
            await supervisor.shutdown()

    return json.loads(asyncio.run(run()))


@pytest.fixture
def ports():
    with ExitStack() as stack:
        yield {
            "v4": listen(socket.AF_INET, "127.0.0.1", stack),
            "v6": listen(socket.AF_INET6, "::1", stack),
        }


def test_seatbelt_denies_worker_networking_and_the_control_connects(tmp_path, ports):
    assert SEATBELT_PROFILE.read_text().strip().endswith("(deny network*)")
    mark = log_mark()
    required = probe(tmp_path, "required", ports)
    required_lookups = dns_lookups(mark)
    mark = log_mark()
    control = probe(tmp_path, "disabled", ports)
    control_lookups = dns_lookups(mark)
    record("probe-required", {**required, "dns_lookups": required_lookups})
    record("probe-disabled-control", {**control, "dns_lookups": control_lookups})

    assert required["sandboxed"] != 0
    for name in ("loopback_v4", "loopback_v6", "external_v4", "external_v6"):
        assert required[name] == DENIED, name
    assert required["udp_dns_v4"] == DENIED
    assert required["dns"].startswith("gaierror:")
    # Seatbelt stops the lookup before it reaches the resolver.
    assert required_lookups == []

    assert control["sandboxed"] == 0
    assert control["loopback_v4"] == control["loopback_v6"] == "connected"
    assert control["external_v4"] == "connected"
    assert control["udp_dns_v4"] == "sent"
    assert control["dns"] == "resolved"
    # The observer the other tests rely on sees the control's lookup.
    assert control_lookups != []


def test_gpu_paths_inside_the_sandboxed_worker_match_the_unsandboxed_worker(
    tmp_path, ports
):
    """MPS (PyTorch) and Metal (MLX) from inside the real worker process, with
    and without Seatbelt. Reported as observed; equality is the claim."""
    required = probe(tmp_path, "required", ports)
    control = probe(tmp_path, "disabled", ports)
    record(
        "gpu",
        {
            "required": [required["mps"], required["metal"]],
            "disabled": [control["mps"], control["metal"]],
        },
    )
    assert required["sandboxed"] != 0 and control["sandboxed"] == 0
    assert required["mps"] == control["mps"]
    assert required["metal"] == control["metal"]
    assert required["metal"]["computed"] is True
