"""How the server launches the worker (TDD sections 1-2; PROTOCOL.md).

Isolation fails closed: required mode prefixes the worker with `sandbox-exec`
and the Seatbelt policy on macOS, and has no implementation anywhere else, so
`argv` returns None and the server refuses with `isolation_unavailable`.
Disabled mode is only ever an explicit configuration choice.
"""

import os
import sys
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path

from hagig.config import NetworkIsolation
from hagig.framing import OFFLINE_ENV

SANDBOX_EXEC = Path("/usr/bin/sandbox-exec")
# backend/src/launcher/seatbelt-v1.sb beside the package. #48 must ship it at
# the same place relative to the installed package.
SEATBELT_PROFILE = (
    Path(__file__).resolve().parent.parent / "launcher" / "seatbelt-v1.sb"
)
WORKER_COMMAND = (sys.executable, "-I", "-m", "hagig.worker")

# The worker inherits nothing else: no proxies, credentials or Python settings.
_PASSTHROUGH = ("HOME", "TMPDIR")
_PATH = "/usr/bin:/bin"


@dataclass(frozen=True)
class Launcher:
    """The worker command and the platform facts isolation depends on."""

    command: tuple[str, ...] = WORKER_COMMAND
    platform: str = sys.platform
    sandbox_exec: Path = SANDBOX_EXEC
    profile: Path = SEATBELT_PROFILE

    def argv(self, mode: NetworkIsolation) -> list[str] | None:
        """The full worker argv, or None when required isolation is unavailable."""
        if mode == "disabled":
            return list(self.command)
        if self.platform != "darwin":
            return None
        if not (os.access(self.sandbox_exec, os.X_OK) and self.profile.is_file()):
            return None
        return [str(self.sandbox_exec), "-f", str(self.profile), *self.command]


def worker_env(env: Mapping[str, str]) -> dict[str, str]:
    """The worker's environment: a fixed allowlist plus offline settings."""
    allowed = {name: env[name] for name in _PASSTHROUGH if name in env}
    return {**allowed, "PATH": _PATH, **OFFLINE_ENV}
