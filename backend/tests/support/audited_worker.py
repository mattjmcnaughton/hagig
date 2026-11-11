"""Test-only worker: the production worker and its real ENGINES, audited.

Launched as `python -I audited_worker.py <record.json>` through the production
`Launcher.argv` (so under `sandbox-exec` in required mode). A Python audit hook
(PEP 578) records, from interpreter start to exit:

- every `socket.*` event (connect, getaddrinfo, sendto, bind, ...);
- every process creation (`subprocess.Popen`, `os.posix_spawn`, `os.exec`,
  `os.system`, `os.fork`);
- every file opened for writing and every filesystem mutation;
- every path opened for reading.

At exit it writes the record as JSON. It sees Python-level operations only:
native code in PyTorch, MLX, tokenizers or hf-xet that never calls into Python
is invisible here (Seatbelt and mDNSResponder observation cover that layer).
Never reachable from the package, configuration, the CLI or the environment.
"""

import atexit
import json
import os
import sys

RECORD = sys.argv[1]
_WRITE_FLAGS = os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_APPEND | os.O_TRUNC
_PROCESS = {"subprocess.Popen", "os.posix_spawn", "os.exec", "os.system", "os.fork"}
_MUTATIONS = {
    "os.mkdir",
    "os.rename",
    "os.remove",
    "os.rmdir",
    "os.link",
    "os.symlink",
    "os.truncate",
    "shutil.rmtree",
    "shutil.copyfile",
    "shutil.move",
}
events: dict[str, list] = {"socket": [], "process": [], "writes": [], "reads": []}
_seen: set[str] = set()


def _path(value) -> str | None:
    if isinstance(value, bytes):
        return os.fsdecode(value)
    return value if isinstance(value, str) else None


def _hook(event: str, args: tuple) -> None:
    if event.startswith("socket."):
        events["socket"].append([event, repr(args)[:200]])
    elif event in _PROCESS:
        events["process"].append([event, repr(args)[:200]])
    elif event in _MUTATIONS:
        events["writes"].append([event, _path(args[0]) if args else None])
    elif event == "open":
        path, mode, flags = args
        path = _path(path)
        if path is None:
            return
        writing = isinstance(mode, str) and any(c in mode for c in "wax+")
        writing = writing or (isinstance(flags, int) and flags & _WRITE_FLAGS)
        if writing:
            events["writes"].append(["open", path])
        elif path not in _seen:
            _seen.add(path)
            events["reads"].append(path)


def _dump() -> None:
    # Snapshot first: the record's own open is not part of it.
    snapshot = json.dumps(events)
    fd = os.open(RECORD, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    os.write(fd, snapshot.encode())
    os.close(fd)


sys.addaudithook(_hook)
atexit.register(_dump)

from hagig.worker import main  # noqa: E402

main()
