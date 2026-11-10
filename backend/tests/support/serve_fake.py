"""Test-only server launcher: the real server with the fake worker injected.

Run as `python -I serve_fake.py '<json options>'` with the test's XDG
environment. Options: `control_dir` (required), `deadlines` (seconds by name),
`grace_seconds`, `hold_file` (after a stop drains, wait for this file before
removing the socket), `sandbox_exec` (override, to make isolation unavailable
on macOS) and `platform`.
"""

import asyncio
import json
import os
import sys
from pathlib import Path

from hagig.launcher import SANDBOX_EXEC, Launcher
from hagig.server import run
from hagig.services.requests import Deadlines

FAKE_WORKER = Path(__file__).resolve().parent / "fake_worker.py"


def main() -> None:
    options = json.loads(sys.argv[1])
    launcher = Launcher(
        command=(sys.executable, "-I", str(FAKE_WORKER), options["control_dir"]),
        platform=options.get("platform", sys.platform),
        sandbox_exec=Path(options.get("sandbox_exec", SANDBOX_EXEC)),
    )
    hold_file = options.get("hold_file")

    async def hold() -> None:
        while hold_file and not os.path.exists(hold_file):
            await asyncio.sleep(0.01)

    raise SystemExit(
        run(
            os.environ,
            launcher=launcher,
            deadlines=Deadlines(**options.get("deadlines", {})),
            grace_seconds=options.get("grace_seconds", 1.0),
            before_exit=hold,
        )
    )


main()
