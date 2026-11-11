"""The real CLI, server and worker with installed models, on macOS (#49).

`Stack` is one isolated user: private config, runtime, HOME and TMPDIR, and a
data directory holding real installations. Observation uses only built-in
macOS tools: `sandbox-exec` with a test-only profile, `log show` and `ps`.

- Networking blocked: required mode runs the worker under the real
  `seatbelt-v1.sb`. The test-only `block` profile wraps a whole CLI
  invocation, so the CLI, the server it spawns and a disabled-mode worker all
  inherit it: outbound IP and the DNS resolver's socket are denied for the
  whole stack. (Seatbelt refuses a second profile inside a sandboxed process,
  so a wrapped stack cannot run required mode's worker.)
- Networking available and observed: disabled mode, unwrapped. mDNSResponder
  logs every lookup with its client PID (`dns_lookups`), so a host-name
  download by any process, including native code, shows up there. The kernel's
  Sandbox violation reports were tried first and rejected: on hosted VMs they
  dropped single attempts entirely.
"""

import asyncio
import ctypes
import json
import os
import pwd
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from hagig.services.supervisor import Supervisor, WorkerSettings

PYTHON = sys.executable
HAGIG = str(Path(sys.executable).parent / "hagig")
SPEECH = Path(__file__).resolve().parents[1] / "fixtures" / "speech.wav"
EVIDENCE = os.environ.get("HAGIG_EVIDENCE_DIR")
_DNS_SOCKET = '(literal "/private/var/run/mDNSResponder")'
BLOCK_PROFILE = (
    "(version 1)\n(allow default)\n"
    "(deny network-outbound (remote ip))\n"
    f"(deny network-outbound {_DNS_SOCKET})\n"
)


def record(name: str, data: object) -> None:
    """Print an observation, and keep it in $HAGIG_EVIDENCE_DIR when set."""
    line = json.dumps(data, sort_keys=True)
    print(f"EVIDENCE {name} {line}")
    if EVIDENCE:
        with open(Path(EVIDENCE) / "observations.jsonl", "a") as sink:
            sink.write(json.dumps({"name": name, "data": data}, sort_keys=True) + "\n")


def sandboxed(pid: int) -> bool:
    check = ctypes.CDLL(None).sandbox_check
    check.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
    check.restype = ctypes.c_int
    return check(pid, None, 0) != 0


def log_mark() -> str:
    """A local timestamp for `log show --start`, one second early."""
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(time.time() - 1))


def dns_lookups(since: str) -> list[str]:
    """mDNSResponder client connections opened by Python processes since
    `since` (one per resolver session). Entries reach the log asynchronously."""
    time.sleep(3)
    shown = subprocess.run(
        [
            "/usr/bin/log",
            "show",
            "--start",
            since,
            "--style",
            "compact",
            "--info",
            "--debug",
            "--predicate",
            'process == "mDNSResponder" AND eventMessage CONTAINS '
            '"DNSServiceCreateConnection START"',
        ],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    return sorted(
        line.split("] ", 2)[-1] for line in shown.splitlines() if "(python3." in line
    )


# PyTorch's import of torch._dynamo (through transformers) creates this empty
# directory in TMPDIR (`torch._inductor.runtime.cache_dir_utils`), after
# `tempfile.gettempdir()` creates and deletes one probe file there. Observed
# on macOS with torch 2.15.0; content-free, but a local write all the same.
# The worker has no USER or LOGNAME, so getpass falls back to the password entry.
TORCH_CACHE_DIR = f"torchinductor_{pwd.getpwuid(os.getuid()).pw_name}"


def written(*roots: Path) -> list[str]:
    """Every file or directory under `roots` (each empty when a Stack starts),
    except PyTorch's empty cache directory (see TORCH_CACHE_DIR)."""
    return sorted(
        str(path)
        for root in roots
        for path in root.rglob("*")
        if not (path.name == TORCH_CACHE_DIR and not any(path.iterdir()))
    )


def processes() -> list[tuple[int, int, str]]:
    shown = subprocess.run(
        ["/bin/ps", "-axo", "pid=,ppid=,command="],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    rows = []
    for line in shown.splitlines():
        pid, ppid, command = line.split(None, 2)
        rows.append((int(pid), int(ppid), command))
    return rows


def transcribe_once(settings: WorkerSettings, audio: bytes) -> str:
    """One request through a real Supervisor, shut down even on failure."""

    async def run() -> str:
        supervisor = Supervisor(settings)
        try:
            return await supervisor.transcribe("once", audio)
        finally:
            await supervisor.shutdown()

    return asyncio.run(run())


def rss_mib(pid: int) -> float | None:
    shown = subprocess.run(
        ["/bin/ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True
    ).stdout.strip()
    return round(int(shown) / 1024, 1) if shown else None


class Stack:
    def __init__(self, root: Path, runtime_base: Path, data: Path) -> None:
        self.root = root
        self.data = data
        self.home, self.tmp = root / "home", root / "tmp"
        self.env = {
            "HOME": str(self.home),
            "TMPDIR": str(self.tmp),
            "XDG_CONFIG_HOME": str(root / "config"),
            "XDG_DATA_HOME": str(data),
            "XDG_RUNTIME_DIR": str(runtime_base),
            "PATH": "/usr/bin:/bin",
        }
        self.home.mkdir()
        self.tmp.mkdir()
        self.config = root / "config" / "hagig" / "config.toml"
        self.config.parent.mkdir(parents=True)
        (root / "block.sb").write_text(BLOCK_PROFILE)
        self._clones: list[Path] = []

    def configure(
        self,
        model_id: str,
        isolation: str = "required",
        terms: tuple[str, ...] = (),
        data: Path | None = None,
    ) -> None:
        """Write the config and choose the data directory. Stop first: the
        server reads both only at startup."""
        self.stop()
        self.env["XDG_DATA_HOME"] = str(data or self.data)
        self.config.write_text(
            f'[model]\nid = "{model_id}"\n'
            f'[inference]\nnetwork_isolation = "{isolation}"\n'
            f"[vocabulary]\nterms = {json.dumps(list(terms))}\n"
        )

    def argv(self, args: tuple[str, ...], block: bool) -> list[str]:
        prefix = ["/usr/bin/sandbox-exec", "-f", str(self.root / "block.sb")]
        return [*(prefix if block else []), HAGIG, *args]

    def cli(
        self, *args: str, block: bool = False, timeout: float = 600
    ) -> subprocess.CompletedProcess:
        return subprocess.run(
            self.argv(args, block),
            env=self.env,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            timeout=timeout,
        )

    def popen(self, *args: str) -> subprocess.Popen:
        return subprocess.Popen(
            self.argv(args, False),
            env=self.env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def status(self) -> dict:
        result = self.cli("status", timeout=30)
        assert result.returncode == 0, result.stderr
        return json.loads(result.stdout)

    def workers(self) -> list[int]:
        """Worker processes whose parent is a Hagig server (one stack at a time)."""
        rows = processes()
        servers = {pid for pid, _, command in rows if "-m hagig.server" in command}
        return [
            pid
            for pid, ppid, command in rows
            if "-m hagig.worker" in command and ppid in servers
        ]

    def stop(self) -> None:
        if self.config.exists():
            subprocess.run(
                [HAGIG, "stop"],
                env=self.env,
                stdin=subprocess.DEVNULL,
                capture_output=True,
                timeout=60,
            )

    def clone(self, model_id: str) -> Path:
        """A data directory holding an APFS clone of one installation (cheap
        to create, private to this test, safe to corrupt)."""
        home = Path(tempfile.mkdtemp(prefix="hagig-clone-", dir=self.data.parent))
        self._clones.append(home)
        models = home / "hagig" / "models"
        models.mkdir(parents=True)
        source = self.data / "hagig" / "models" / model_id
        subprocess.run(["/bin/cp", "-cR", str(source), str(models)], check=True)
        return home

    def cleanup(self) -> None:
        self.stop()
        for home in self._clones:
            shutil.rmtree(home, ignore_errors=True)
