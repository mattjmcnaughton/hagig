import os
import socket
import stat
import subprocess
import sys
import textwrap
from pathlib import Path

import pytest

from hagig.paths import (
    PathError,
    ServerLock,
    config_file,
    ensure_runtime_dir,
    models_dir,
    socket_path,
)

UID = os.getuid()


def mode(path):
    return stat.S_IMODE(os.lstat(path).st_mode)


def private_dir(path):
    path.mkdir(mode=0o700)
    path.chmod(0o700)
    return path


def resolve(env, tmp_path, **kwargs):
    kwargs.setdefault("platform", "linux")
    kwargs.setdefault("tmp_root", tmp_path / "tmp")
    (tmp_path / "tmp").mkdir(exist_ok=True)
    return ensure_runtime_dir(env, **kwargs)


# XDG configuration and data locations


@pytest.mark.parametrize(
    ("env", "expected"),
    [
        ({"HOME": "/home/u"}, "/home/u/.config/hagig/config.toml"),
        (
            {"HOME": "/home/u", "XDG_CONFIG_HOME": ""},
            "/home/u/.config/hagig/config.toml",
        ),
        (
            {"HOME": "/home/u", "XDG_CONFIG_HOME": "rel"},
            "/home/u/.config/hagig/config.toml",
        ),
        ({"HOME": "/home/u", "XDG_CONFIG_HOME": "/x/cfg"}, "/x/cfg/hagig/config.toml"),
    ],
)
def test_config_file_follows_xdg(env, expected):
    assert config_file(env) == Path(expected)


@pytest.mark.parametrize(
    ("env", "expected"),
    [
        ({"HOME": "/home/u"}, "/home/u/.local/share/hagig/models"),
        (
            {"HOME": "/home/u", "XDG_DATA_HOME": "rel"},
            "/home/u/.local/share/hagig/models",
        ),
        ({"HOME": "/home/u", "XDG_DATA_HOME": "/x/data"}, "/x/data/hagig/models"),
    ],
)
def test_models_dir_follows_xdg(env, expected):
    assert models_dir(env) == Path(expected)


@pytest.mark.parametrize("env", [{}, {"HOME": ""}, {"HOME": "relative"}])
def test_missing_home_fails_closed(env):
    with pytest.raises(PathError) as error:
        config_file(env)
    assert error.value.code == "home_unavailable"


# Runtime directory selection


def test_valid_xdg_runtime_dir_gets_a_private_hagig_child(tmp_path):
    base = private_dir(tmp_path / "run")
    path = resolve({"XDG_RUNTIME_DIR": str(base)}, tmp_path)
    assert path == base / "hagig"
    assert mode(path) == 0o700
    assert not (tmp_path / "tmp" / f"hagig-{UID}").exists()


def test_symlinked_xdg_runtime_base_is_followed(tmp_path):
    # The base comes from the environment; only the hagig child must not be a link.
    real = private_dir(tmp_path / "real")
    link = tmp_path / "link"
    link.symlink_to(real)
    path = resolve({"XDG_RUNTIME_DIR": str(link)}, tmp_path)
    assert path == link / "hagig"
    assert (real / "hagig").is_dir()


def test_existing_private_runtime_dir_is_reused(tmp_path):
    base = private_dir(tmp_path / "run")
    first = resolve({"XDG_RUNTIME_DIR": str(base)}, tmp_path)
    (first / "keep").write_text("")
    assert resolve({"XDG_RUNTIME_DIR": str(base)}, tmp_path) == first
    assert (first / "keep").exists()


@pytest.mark.parametrize(
    "kind", ["unset", "relative", "group-readable", "missing", "file"]
)
def test_invalid_xdg_runtime_dir_falls_back_to_tmp_on_linux(tmp_path, kind):
    env = {}
    if kind == "relative":
        env["XDG_RUNTIME_DIR"] = "run"
    elif kind == "group-readable":
        base = tmp_path / "run"
        base.mkdir()
        base.chmod(0o750)
        env["XDG_RUNTIME_DIR"] = str(base)
    elif kind == "missing":
        env["XDG_RUNTIME_DIR"] = str(tmp_path / "absent")
    elif kind == "file":
        (tmp_path / "run").write_text("")
        env["XDG_RUNTIME_DIR"] = str(tmp_path / "run")
    path = resolve(env, tmp_path)
    assert path == tmp_path / "tmp" / f"hagig-{UID}"
    assert mode(path) == 0o700
    assert not (tmp_path / "run" / "hagig").exists()


def test_xdg_runtime_dir_owned_by_another_user_is_not_used(tmp_path):
    base = private_dir(tmp_path / "run")
    # Pretend to be a different user: everything on disk now belongs to someone else.
    with pytest.raises(PathError) as error:
        resolve({"XDG_RUNTIME_DIR": str(base)}, tmp_path, uid=UID + 1)
    assert error.value.code == "runtime_dir_unsafe"
    assert not (base / "hagig").exists()


def test_macos_uses_the_per_user_temp_dir(tmp_path):
    user_temp = private_dir(tmp_path / "T")
    path = resolve(
        {}, tmp_path, platform="darwin", darwin_temp_dir=lambda: str(user_temp)
    )
    assert path == user_temp / "hagig"
    assert mode(path) == 0o700


@pytest.mark.parametrize("result", [None, "", "relative"])
def test_macos_without_a_per_user_temp_dir_fails_closed(tmp_path, result):
    with pytest.raises(PathError) as error:
        resolve(
            {"TMPDIR": str(private_dir(tmp_path / "T"))},
            tmp_path,
            platform="darwin",
            darwin_temp_dir=lambda: result,
        )
    assert error.value.code == "runtime_dir_unavailable"
    assert not (tmp_path / "T" / "hagig").exists()
    assert not (tmp_path / "tmp" / f"hagig-{UID}").exists()


def test_macos_temp_dir_that_is_not_private_fails_closed(tmp_path):
    shared = tmp_path / "T"
    shared.mkdir()
    shared.chmod(0o755)
    with pytest.raises(PathError) as error:
        resolve({}, tmp_path, platform="darwin", darwin_temp_dir=lambda: str(shared))
    assert error.value.code == "runtime_dir_unsafe"
    assert not (shared / "hagig").exists()


# Fail closed on unsafe preexisting objects, without repairing them


def test_preexisting_runtime_dir_with_loose_mode_is_refused_untouched(tmp_path):
    existing = tmp_path / "tmp" / f"hagig-{UID}"
    existing.parent.mkdir()
    existing.mkdir()
    existing.chmod(0o755)
    with pytest.raises(PathError) as error:
        resolve({}, tmp_path)
    assert error.value.code == "runtime_dir_unsafe"
    assert mode(existing) == 0o755


def test_symlinked_runtime_dir_is_refused(tmp_path):
    target = private_dir(tmp_path / "elsewhere")
    link = tmp_path / "tmp" / f"hagig-{UID}"
    link.parent.mkdir()
    link.symlink_to(target)
    with pytest.raises(PathError) as error:
        resolve({}, tmp_path)
    assert error.value.code == "runtime_dir_unsafe"
    assert link.is_symlink()
    assert list(target.iterdir()) == []


def test_regular_file_at_runtime_dir_is_refused(tmp_path):
    existing = tmp_path / "tmp" / f"hagig-{UID}"
    existing.parent.mkdir()
    existing.write_text("x")
    with pytest.raises(PathError) as error:
        resolve({}, tmp_path)
    assert error.value.code == "runtime_dir_unsafe"
    assert existing.read_text() == "x"


def test_runtime_dir_owned_by_another_user_is_refused(tmp_path):
    with pytest.raises(PathError) as error:
        resolve({}, tmp_path, uid=UID + 1)
    assert error.value.code == "runtime_dir_unsafe"


def test_errors_do_not_include_paths(tmp_path):
    secret = tmp_path / "SENTINEL-user-name"
    secret.mkdir()
    secret.chmod(0o755)
    with pytest.raises(PathError) as error:
        resolve({}, tmp_path, platform="darwin", darwin_temp_dir=lambda: str(secret))
    assert "SENTINEL" not in str(error.value)
    assert "SENTINEL" not in repr(error.value)
    assert error.value.__context__ is None


def test_uncreatable_runtime_dir_is_unavailable_without_chaining(tmp_path):
    with pytest.raises(PathError) as error:
        resolve({}, tmp_path, tmp_root=tmp_path / "SENTINEL-absent")
    assert error.value.code == "runtime_dir_unavailable"
    assert error.value.__context__ is None


# Socket path length


def _limit(platform):
    return 104 if platform == "darwin" else 108


@pytest.mark.parametrize("platform", ["darwin", "linux"])
def test_socket_path_length_is_checked_with_room_for_the_terminator(tmp_path, platform):
    limit = _limit(platform)
    suffix = len("/server.sock")
    fits = Path("/" + "a" * (limit - 1 - suffix - 1))
    too_long = Path("/" + "a" * (limit - suffix - 1))
    assert len(os.fsencode(socket_path(fits, platform=platform))) == limit - 1
    with pytest.raises(PathError) as error:
        socket_path(too_long, platform=platform)
    assert error.value.code == "socket_path_too_long"


def test_longest_accepted_socket_path_binds_on_this_platform(tmp_path):
    limit = _limit(sys.platform)
    room = limit - 1 - len(os.fsencode(str(tmp_path))) - len("/server.sock") - 1
    if room < 1:
        pytest.skip("temporary directory too long to build a boundary path")
    runtime = tmp_path / ("d" * room)
    runtime.mkdir()
    path = socket_path(runtime, platform=sys.platform)
    assert len(os.fsencode(path)) == limit - 1
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
        server.bind(os.fspath(path))


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS per-user temp dir")
def test_real_macos_per_user_temp_dir_is_private_and_matches_tmpdir(tmp_path):
    path = ensure_runtime_dir({}, tmp_root=tmp_path)
    assert path.name == "hagig"
    assert mode(path) == 0o700
    assert os.lstat(path.parent).st_uid == UID
    if os.environ.get("TMPDIR"):
        assert os.path.realpath(path.parent) == os.path.realpath(os.environ["TMPDIR"])


# Server lock


def test_lock_is_a_persistent_private_file_that_is_never_unlinked(tmp_path):
    runtime = private_dir(tmp_path / "rt")
    lock = ServerLock.acquire(runtime)
    assert lock is not None
    lock_file = runtime / "server.lock"
    assert mode(lock_file) == 0o600
    inode = os.stat(lock_file).st_ino
    lock.release()
    assert os.stat(lock_file).st_ino == inode
    again = ServerLock.acquire(runtime)
    assert again is not None
    assert os.stat(lock_file).st_ino == inode
    again.release()


def test_lock_excludes_a_second_holder_until_released(tmp_path):
    runtime = private_dir(tmp_path / "rt")
    held = ServerLock.acquire(runtime)
    assert held is not None
    assert ServerLock.acquire(runtime) is None
    held.release()
    second = ServerLock.acquire(runtime)
    assert second is not None
    second.release()


def _other_process_acquires(runtime):
    script = textwrap.dedent(
        f"""
        import sys
        from pathlib import Path
        from hagig.paths import ServerLock
        lock = ServerLock.acquire(Path({str(runtime)!r}))
        sys.exit(0 if lock is not None else 3)
        """
    )
    return subprocess.run([sys.executable, "-c", script], check=False).returncode


def test_lock_excludes_another_process_and_is_released_on_exit(tmp_path):
    runtime = private_dir(tmp_path / "rt")
    lock = ServerLock.acquire(runtime)
    assert lock is not None
    assert _other_process_acquires(runtime) == 3
    lock.release()
    assert _other_process_acquires(runtime) == 0
    # The other process exited holding the lock; exit released it.
    after = ServerLock.acquire(runtime)
    assert after is not None
    after.release()


def test_lock_file_with_loose_mode_is_refused_untouched(tmp_path):
    runtime = private_dir(tmp_path / "rt")
    lock_file = runtime / "server.lock"
    lock_file.write_text("")
    lock_file.chmod(0o644)
    with pytest.raises(PathError) as error:
        ServerLock.acquire(runtime)
    assert error.value.code == "lock_file_unsafe"
    assert mode(lock_file) == 0o644


def test_symlinked_lock_file_is_refused(tmp_path):
    runtime = private_dir(tmp_path / "rt")
    target = tmp_path / "target"
    target.write_text("")
    target.chmod(0o600)
    (runtime / "server.lock").symlink_to(target)
    with pytest.raises(PathError) as error:
        ServerLock.acquire(runtime)
    assert error.value.code == "lock_file_unsafe"


def test_lock_file_owned_by_another_user_is_refused(tmp_path):
    runtime = private_dir(tmp_path / "rt")
    with pytest.raises(PathError) as error:
        ServerLock.acquire(runtime, uid=UID + 1)
    assert error.value.code == "lock_file_unsafe"


def test_non_regular_lock_file_is_refused(tmp_path):
    runtime = private_dir(tmp_path / "rt")
    os.mkfifo(runtime / "server.lock", 0o600)
    with pytest.raises(PathError) as error:
        ServerLock.acquire(runtime)
    assert error.value.code == "lock_file_unsafe"


def test_lock_in_a_missing_directory_is_unavailable_not_unsafe(tmp_path):
    with pytest.raises(PathError) as error:
        ServerLock.acquire(tmp_path / "SENTINEL-missing")
    assert error.value.code == "lock_unavailable"
    assert error.value.__context__ is None
