"""Filesystem locations and the server lifetime lock (TDD sections 3 and 5).

Configuration and models follow XDG. The runtime directory holding the socket
and lock is private (0700) and owner-validated; an unsafe preexisting object
fails closed and is never repaired or deleted. The server lock is a persistent
0600 `server.lock` held with `fcntl.flock` and never unlinked, so every
contender locks the same inode.

Errors carry a stable code and never a path or OS error text.
"""

import ctypes
import errno
import fcntl
import os
import stat
import sys
from collections.abc import Callable, Mapping
from pathlib import Path
from typing import Self

SOCKET_NAME = "server.sock"
LOCK_NAME = "server.lock"
_CS_DARWIN_USER_TEMP_DIR = 65537


class PathError(Exception):
    """A location is unavailable or unsafe. `code` is stable and content-free."""

    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


def config_file(env: Mapping[str, str]) -> Path:
    """`$XDG_CONFIG_HOME/hagig/config.toml`, default `~/.config/...`."""
    return _xdg(env, "XDG_CONFIG_HOME", ".config") / "hagig" / "config.toml"


def models_dir(env: Mapping[str, str]) -> Path:
    """`$XDG_DATA_HOME/hagig/models`, default `~/.local/share/...`."""
    return _xdg(env, "XDG_DATA_HOME", ".local/share") / "hagig" / "models"


def _xdg(env: Mapping[str, str], name: str, default: str) -> Path:
    # The XDG spec says relative values are invalid and must be ignored.
    value = env.get(name, "")
    if os.path.isabs(value):
        return Path(value)
    home = env.get("HOME", "")
    if not os.path.isabs(home):
        raise PathError("home_unavailable")
    return Path(home) / default


def _darwin_user_temp_dir() -> str | None:
    libc = ctypes.CDLL(None)
    confstr = libc.confstr
    confstr.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_size_t]
    confstr.restype = ctypes.c_size_t
    size = confstr(_CS_DARWIN_USER_TEMP_DIR, None, 0)
    if size == 0:
        return None
    buffer = ctypes.create_string_buffer(size)
    if confstr(_CS_DARWIN_USER_TEMP_DIR, buffer, size) == 0:
        return None
    return os.fsdecode(buffer.value)


def ensure_runtime_dir(
    env: Mapping[str, str],
    *,
    platform: str = sys.platform,
    uid: int | None = None,
    tmp_root: Path = Path("/tmp"),
    darwin_temp_dir: Callable[[], str | None] = _darwin_user_temp_dir,
) -> Path:
    """Create or validate the private per-user runtime directory.

    Prefers a valid owner-only `$XDG_RUNTIME_DIR/hagig`. Otherwise macOS uses
    `hagig` inside the OS per-user temporary directory (failing closed if the
    OS provides none), and other platforms use `<tmp_root>/hagig-<uid>`.
    """
    uid = os.getuid() if uid is None else uid
    xdg = env.get("XDG_RUNTIME_DIR", "")
    if os.path.isabs(xdg) and _is_private_dir(xdg, uid, follow_symlinks=True):
        runtime = Path(xdg) / "hagig"
    elif platform == "darwin":
        base = darwin_temp_dir()
        if not base or not os.path.isabs(base):
            raise PathError("runtime_dir_unavailable")
        if not _is_private_dir(base, uid, follow_symlinks=True):
            raise PathError("runtime_dir_unsafe")
        runtime = Path(base) / "hagig"
    else:
        runtime = tmp_root / f"hagig-{uid}"
    return _ensure_private_dir(runtime, uid)


def _is_private_dir(path: str | Path, uid: int, *, follow_symlinks: bool) -> bool:
    try:
        info = os.stat(path, follow_symlinks=follow_symlinks)
    except OSError:
        return False
    return (
        stat.S_ISDIR(info.st_mode)
        and info.st_uid == uid
        and stat.S_IMODE(info.st_mode) == 0o700
    )


def _ensure_private_dir(path: Path, uid: int) -> Path:
    # Errors here and below are raised outside their except blocks so no OS
    # error (which carries the path) is chained onto them.
    created = True
    try:
        os.mkdir(path, 0o700)
    except FileExistsError:
        pass
    except OSError:
        created = False
    if not created:
        raise PathError("runtime_dir_unavailable")
    # lstat: a symlink, even to a private directory, is substitution.
    if not _is_private_dir(path, uid, follow_symlinks=False):
        raise PathError("runtime_dir_unsafe")
    return path


def socket_path(runtime: Path, *, platform: str = sys.platform) -> Path:
    """The server socket path, checked against the Unix-socket length limit."""
    path = runtime / SOCKET_NAME
    # sizeof(sockaddr_un.sun_path); the path also needs a terminating NUL.
    limit = 104 if platform == "darwin" else 108
    if len(os.fsencode(path)) >= limit:
        raise PathError("socket_path_too_long")
    return path


class ServerLock:
    """Exclusive lock on a persistent 0600 file, by default `<runtime>/server.lock`.

    The model installer takes the same kind of lock on its own file.
    """

    def __init__(self, fd: int) -> None:
        self._fd = fd

    @classmethod
    def acquire(
        cls, runtime: Path, *, uid: int | None = None, name: str = LOCK_NAME
    ) -> Self | None:
        """Take the lock, or return None if another holder has it."""
        uid = os.getuid() if uid is None else uid
        flags = os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
        failure = "lock_unavailable"
        try:
            fd = os.open(runtime / name, flags, 0o600)
        except OSError as error:
            # ELOOP: O_NOFOLLOW met a symlink, a substituted object.
            if error.errno == errno.ELOOP:
                failure = "lock_file_unsafe"
            fd = -1
        if fd < 0:
            raise PathError(failure)
        info = os.fstat(fd)
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != uid
            or stat.S_IMODE(info.st_mode) != 0o600
        ):
            os.close(fd)
            raise PathError("lock_file_unsafe")
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(fd)
            return None
        except OSError:
            pass
        else:
            return cls(fd)
        os.close(fd)
        raise PathError("lock_unavailable")

    def release(self) -> None:
        """Release the lock. The file stays in place."""
        if self._fd >= 0:
            os.close(self._fd)
            self._fd = -1
