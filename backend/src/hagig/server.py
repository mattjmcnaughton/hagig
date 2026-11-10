"""The server process (TDD section 5; backend/PROTOCOL.md).

Started on demand by a client as `python -I -m hagig.server`. It takes the
lifetime lock; a loser exits 0 so its client attaches to the winner. Only the
lock holder removes a stale socket, and it binds the private socket itself,
0600 from creation, for uvicorn to serve. There is no TCP listener. After
`POST /v1/stop`, SIGTERM or SIGINT it answers active work, reaps the worker,
removes its socket and exits.
"""

import asyncio
import contextlib
import logging
import os
import signal
import socket
import stat
from collections.abc import Awaitable, Callable, Generator, Mapping
from pathlib import Path

import structlog
import uvicorn

from hagig.app import create_app
from hagig.config import Config, ConfigError, load_config
from hagig.launcher import Launcher, worker_env
from hagig.logging import configure_logging
from hagig.paths import (
    PathError,
    ServerLock,
    config_file,
    ensure_runtime_dir,
    models_dir,
    socket_path,
)
from hagig.services.requests import Deadlines, RequestService
from hagig.services.supervisor import Supervisor, WorkerSettings

log = structlog.get_logger()

EXIT_FAILURE = 1
EXIT_CONFIG = 2
# uvicorn's bound for connections still open at exit; stop drains first.
_SHUTDOWN_SECONDS = 3


class _Server(uvicorn.Server):
    @contextlib.contextmanager
    def capture_signals(self) -> Generator[None, None, None]:
        # `_serve` turns SIGTERM and SIGINT into a stop. uvicorn's handler
        # would re-raise the signal on exit, before the worker is reaped.
        yield


def run(
    env: Mapping[str, str],
    *,
    launcher: Launcher | None = None,
    deadlines: Deadlines | None = None,
    grace_seconds: float = 1.0,
    before_exit: Callable[[], Awaitable[None]] | None = None,
) -> int:
    """Serve until stopped. Returns the process exit status.

    `before_exit` runs after a stop has drained, before the socket is removed;
    tests use it to hold the stopping state.
    """
    configure_logging()
    _silence_stdlib_loggers()
    code = None
    try:
        config = load_config(config_file(env))
        runtime = ensure_runtime_dir(env)
        path = socket_path(runtime)
        models = models_dir(env)
        lock = ServerLock.acquire(runtime)
    except (ConfigError, PathError) as error:
        code = error.code
    if code is not None:
        log.error("server_start_failed", code=code)
        return EXIT_CONFIG if code.startswith("config") else EXIT_FAILURE
    if lock is None:
        log.info("server_already_running")
        return 0
    inode = None
    try:
        sock, inode = _bind(path)
        settings = WorkerSettings(
            launcher=launcher or Launcher(),
            mode=config.inference.network_isolation,
            env=worker_env(env),
            models_root=models,
            model_id=config.model.id,
            vocabulary=tuple(config.vocabulary.terms),
            grace_seconds=grace_seconds,
        )
        asyncio.run(
            _serve(
                config,
                settings,
                deadlines or Deadlines(),
                sock,
                before_exit,
                lambda: _unlink_ours(path, inode),
            )
        )
    except PathError as error:
        log.error("server_start_failed", code=error.code)
        return EXIT_FAILURE
    finally:
        if inode is not None:
            _unlink_ours(path, inode)
        lock.release()
    log.info("server_stopped")
    return 0


async def _serve(
    config: Config,
    settings: WorkerSettings,
    deadlines: Deadlines,
    sock: socket.socket,
    before_exit: Callable[[], Awaitable[None]] | None,
    remove_socket: Callable[[], None],
) -> None:
    supervisor = Supervisor(settings)
    service = RequestService(config, supervisor, deadlines)
    server = _Server(
        uvicorn.Config(
            create_app(service),
            ws="none",
            lifespan="off",
            access_log=False,
            log_config=None,
            server_header=False,
            use_colors=False,
            timeout_graceful_shutdown=_SHUTDOWN_SECONDS,
        )
    )
    log.info("server_started", mode=settings.mode)
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, service.stop)
    serving = asyncio.create_task(server.serve(sockets=[sock]))
    stopped = asyncio.create_task(service.stop_requested.wait())
    try:
        await asyncio.wait({serving, stopped}, return_when=asyncio.FIRST_COMPLETED)
        if stopped.done() and not serving.done():
            await service.drain()
            if before_exit is not None:
                await before_exit()
            # New clients now see a refused connection; then the listener closes.
            remove_socket()
            server.should_exit = True
        await serving
    finally:
        stopped.cancel()
        await supervisor.shutdown()


def _bind(path: Path) -> tuple[socket.socket, int]:
    """Bind the private socket, removing a stale one first. We hold the lock."""
    uid = os.getuid()
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        info = None
    if info is not None:
        # Only an owner-validated socket is stale; anything else fails closed.
        if not stat.S_ISSOCK(info.st_mode) or info.st_uid != uid:
            raise PathError("socket_unsafe")
        os.unlink(path)
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    bound = False
    previous = os.umask(0o177)
    try:
        sock.bind(os.fsencode(path))
        bound = True
    except OSError:
        pass
    finally:
        os.umask(previous)
    if not bound:
        sock.close()
        raise PathError("socket_unavailable")
    info = os.lstat(path)
    if stat.S_IMODE(info.st_mode) != 0o600 or info.st_uid != uid:
        sock.close()
        raise PathError("socket_unsafe")
    sock.listen(64)
    return sock, info.st_ino


def _unlink_ours(path: Path, inode: int) -> None:
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return
    if stat.S_ISSOCK(info.st_mode) and info.st_ino == inode:
        os.unlink(path)


def _silence_stdlib_loggers() -> None:
    # uvicorn's and asyncio's loggers bypass the structlog allowlist, and
    # Python's last-resort handler would print their warnings and tracebacks.
    # uvicorn.access is cut off from "uvicorn" (propagate=False) by
    # access_log=False, so it needs its own handler to avoid lastResort.
    for name in ("uvicorn", "uvicorn.error", "uvicorn.access", "asyncio", "fastapi"):
        logger = logging.getLogger(name)
        logger.handlers = [logging.NullHandler()]
        logger.propagate = False


def main() -> None:
    raise SystemExit(run(os.environ))


if __name__ == "__main__":
    main()
