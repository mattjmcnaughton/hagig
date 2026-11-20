"""Command-line interface (TDD section 9; PROTOCOL.md, Client rules).

`start` starts or attaches to the server; `status` and `stop` never start one.
`transcribe` reserves a request, decodes the WAV file, uploads canonical audio
and prints only the text on stdout. `uninstall` stops the server and removes
settings, models and runtime files. stderr carries stable codes only. Exit
codes: 0 success (including no speech), 1 failure, 2 usage or configuration
error, 3 busy, 130 interrupted.
"""

import contextlib
import importlib.util
import os
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import time
from collections.abc import Generator, Mapping
from pathlib import Path
from typing import Annotated, Any, NoReturn

import httpx
import typer

from hagig.client import Client, Outcome, UnreachableError
from hagig.config import ConfigError, is_apple_silicon, load_config
from hagig.contract import EXCHANGE_SECONDS, encode_json
from hagig.installer import InstallError, install
from hagig.manifest import ManifestError, load_manifest
from hagig.models import INSTALL_LOCK_NAME
from hagig.paths import (
    LOCK_NAME,
    PathError,
    ServerLock,
    config_file,
    ensure_runtime_dir,
    models_dir,
    runtime_dir,
    socket_path,
)
from hagig.wav import WavError, read_wav

EXIT_FAILURE = 1
EXIT_USAGE = 2
EXIT_BUSY = 3
EXIT_INTERRUPTED = 130

STOP_SECONDS = 15.0
_POLL_SECONDS = 0.05
SERVER_COMMAND = (sys.executable, "-I", "-m", "hagig.server")

app = typer.Typer(no_args_is_help=True, add_completion=False)
model_app = typer.Typer(no_args_is_help=True)
app.add_typer(model_app, name="model", help="Manage local models.")


def _fail(code: str, exit_code: int = EXIT_FAILURE) -> NoReturn:
    typer.echo(code, err=True)
    raise typer.Exit(exit_code)


def _report(outcome: Outcome) -> NoReturn:
    if outcome.kind == "failure" and outcome.code is not None:
        _fail(outcome.code, EXIT_BUSY if outcome.code == "busy" else EXIT_FAILURE)
    _fail(outcome.kind)


def _runtime(env: Mapping[str, str]) -> tuple[Path, Path]:
    code = None
    try:
        runtime = ensure_runtime_dir(env)
        return runtime, socket_path(runtime)
    except PathError as error:
        code = error.code
    _fail(code)


def _check_config(env: Mapping[str, str]) -> None:
    """Fail with an actionable, content-free message before spawning a server."""
    try:
        path = config_file(env)
    except PathError as error:
        _fail(error.code, EXIT_USAGE)
    try:
        load_config(path)
        return
    except ConfigError as error:
        failure = error
    if any(i.field == "model.id" and i.code == "missing" for i in failure.issues):
        _fail(f"config_invalid: model.id missing; set [model] id in {path}", EXIT_USAGE)
    _fail(f"{failure} ({path})", EXIT_USAGE)


def _ensure_server(env: Mapping[str, str]) -> tuple[Path, dict[str, Any]]:
    """Attach to the running server, or spawn one once, within 5 seconds."""
    _runtime_dir, sock = _runtime(env)
    spawned: subprocess.Popen[bytes] | None = None
    deadline = time.monotonic() + EXCHANGE_SECONDS
    while True:
        with Client(sock) as client:
            try:
                outcome: Outcome | None = client.status()
            except UnreachableError:
                outcome = None
        if outcome is not None and outcome.kind == "compatible":
            return sock, outcome.data
        if outcome is not None and outcome.kind == "incompatible_api":
            _fail("incompatible_api")
        # Otherwise no server answers, or one is stopping: wait for it to go.
        if outcome is None and spawned is None:
            _check_config(env)
            spawned = subprocess.Popen(
                SERVER_COMMAND,
                env=dict(env),
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                cwd="/",
                close_fds=True,
                start_new_session=True,
            )
        elif spawned is not None and spawned.poll() not in (None, 0):
            _fail("server_start_failed")
        if time.monotonic() >= deadline:
            _fail("server_start_failed")
        time.sleep(_POLL_SECONDS)


@app.command()
def start() -> None:
    """Start or attach to the server."""
    _ensure_server(os.environ)


@contextlib.contextmanager
def _holding_interrupts() -> Generator[None]:
    """Defer Ctrl-C to the end of the block, then raise it there.

    The server is busy from the moment it admits, but the client only learns
    the request ID from the 201. Holding the interrupt over the admission
    exchange (bounded by its 5 s timeout) means a Ctrl-C always ends with a
    known ID to DELETE, instead of a reservation left to the upload-start
    deadline. An inherited SIG_IGN stays in force.
    """
    if signal.getsignal(signal.SIGINT) is not signal.default_int_handler:
        yield
        return
    interrupted = False

    def note(_signum: int, _frame: object) -> None:
        nonlocal interrupted
        interrupted = True

    signal.signal(signal.SIGINT, note)
    try:
        yield
    finally:
        signal.signal(signal.SIGINT, signal.default_int_handler)
    if interrupted:
        raise KeyboardInterrupt


@app.command()
def transcribe(audio: Path) -> None:
    """Transcribe a WAV file and print the text."""
    sock: Path | None = None
    admitted_id: str | None = None
    try:
        sock, status_data = _ensure_server(os.environ)
        with Client(sock) as client:
            with _holding_interrupts():
                admitted = client.admit()
                if admitted.kind == "admitted":
                    admitted_id = admitted.data["request_id"]
            if admitted_id is None:
                _report(admitted)
            if (
                admitted.data["config_generation"] != status_data["config_generation"]
                or admitted.data["model_id"] != status_data["settings"]["model_id"]
            ):
                # The server restarted between status and admission.
                client.cancel(admitted_id)
                _fail("generic_failure")
            wav_code = None
            try:
                pcm = read_wav(audio)
            except WavError as error:
                wav_code = error.code
            if wav_code is not None:
                client.cancel(admitted_id)
                _fail(wav_code, EXIT_USAGE)
            outcome = client.upload(admitted_id, pcm.astype("<f4").tobytes())
    except KeyboardInterrupt:
        # Invalidate first: no more output. Leaving the client closed any
        # upload connection, which cancels; DELETE also ends a reservation
        # that no upload owns yet, and is harmless otherwise.
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        if sock is not None and admitted_id is not None:
            with Client(sock) as client:
                client.cancel(admitted_id)
        raise typer.Exit(EXIT_INTERRUPTED) from None
    if outcome.kind == "text":
        sys.stdout.write(f"{outcome.text}\n")
        sys.stdout.flush()
        return
    if outcome.kind == "empty":
        return
    _report(outcome)


@app.command()
def status() -> None:
    """Report server status without starting it."""
    _runtime_dir, sock = _runtime(os.environ)
    with Client(sock) as client:
        try:
            outcome = client.status()
        except UnreachableError:
            typer.echo("stopped")
            return
    if outcome.kind != "compatible":
        _report(outcome)
    typer.echo(encode_json(outcome.data).decode())


@app.command()
def stop() -> None:
    """Stop a running server and wait until it has exited."""
    _stop_server(*_runtime(os.environ))


def _stop_server(runtime: Path, sock: Path) -> None:
    with Client(sock) as client:
        try:
            outcome = client.status()
        except UnreachableError:
            return
        if outcome.kind == "incompatible_api":
            _fail("incompatible_api")
        if outcome.kind == "compatible":
            client.stop()
    deadline = time.monotonic() + STOP_SECONDS
    while time.monotonic() < deadline:
        if not sock.exists():
            try:
                lock = ServerLock.acquire(runtime)
            except PathError as error:
                _fail(error.code)
            if lock is not None:
                lock.release()
                return
        time.sleep(_POLL_SECONDS)
    _fail("stop_timeout")


BUNDLE_ID = "com.mattjmcnaughton.hagig"


@app.command()
def uninstall(
    yes: Annotated[
        bool, typer.Option("--yes", "-y", help="Do not ask for confirmation.")
    ] = False,
) -> None:
    """Stop the server and remove settings, models and runtime files.

    The app bundle is left in place; the command prints how to remove it.
    Exit 0 removed, 1 failure or declined.
    """
    env = os.environ
    code = None
    try:
        config = config_file(env).parent
        models = models_dir(env)
        runtime = runtime_dir(env)
    except PathError as error:
        code = error.code
    if code is not None:
        _fail(code)
    data = models.parent
    if not yes:
        typer.echo("This stops the Hagig server and permanently removes:")
        for path in (config, data, runtime):
            typer.echo(f"  {path}")
        typer.echo("Quit Hagig first, or it starts the server again.")
        confirmed = False
        with contextlib.suppress(typer.Abort):
            confirmed = typer.confirm("Continue?", default=False)
        if not confirmed:
            _fail("cancelled")
    # Only now: `_runtime` creates the runtime directory.
    runtime, sock = _runtime(env)
    _stop_server(runtime, sock)
    _remove(runtime, models, config, data)
    typer.echo("Removed Hagig's settings, models and runtime files.")
    # Never delete the bundle this CLI runs from, under a possibly running app.
    bundle = _app_bundle()
    typer.echo("To finish, quit Hagig, then delete the app and its microphone access:")
    typer.echo(
        f"  rm -rf {shlex.quote(str(bundle))}" if bundle else "  (delete Hagig.app)"
    )
    typer.echo(f"  tccutil reset Microphone {BUNDLE_ID}")


def _remove(runtime: Path, models: Path, config: Path, data: Path) -> None:
    """Remove data and config, then runtime, holding the server and install locks.

    `shutil.rmtree` never follows symlinks and refuses a symlinked top level,
    which is `uninstall_failed` like any other filesystem error.
    """
    wanted = [(runtime, LOCK_NAME, "server_running")]
    if _is_real_dir(models):
        wanted.append((models, INSTALL_LOCK_NAME, "install_in_progress"))
    code = None
    locks: list[ServerLock] = []
    try:
        for directory, name, held in wanted:
            lock = ServerLock.acquire(directory, name=name)
            if lock is None:
                code = held
                break
            locks.append(lock)
        else:
            for path in (data, config, runtime):
                if os.path.lexists(path):
                    shutil.rmtree(path)
    except PathError as error:
        code = error.code
    except OSError:
        code = "uninstall_failed"
    finally:
        for lock in locks:
            lock.release()
    if code is not None:
        _fail(code)


def _is_real_dir(path: Path) -> bool:
    try:
        return stat.S_ISDIR(os.lstat(path).st_mode)
    except OSError:
        return False


def _app_bundle() -> Path | None:
    """The `.app` this CLI runs from (`.../Hagig.app/Contents/...`), if any."""
    for parent in Path(sys.executable).parents:
        if parent.suffix == ".app":
            return parent
    return None


# Generous per-read bound for multi-gigabyte downloads over slow links.
_DOWNLOAD_TIMEOUT = httpx.Timeout(30.0, read=120.0)
_INSTALL_EXITS = {
    "unknown_model": EXIT_USAGE,
    "model_unsupported_on_platform": EXIT_USAGE,
    "interrupted": EXIT_INTERRUPTED,
}


@model_app.command("install")
def model_install(manifest_id: str) -> None:
    """Explicitly download, verify and publish a model (the only network step).

    Prints `installed` or `already_installed`. stderr carries progress as
    `<event> [<manifest file>]` and failures as `<code>[: <manifest file>]`.
    Exit 0 success, 1 failure, 2 unknown or unsupported model, 130 interrupted.
    """
    try:
        typer.echo(_install(manifest_id, os.environ))
        return
    except (ManifestError, PathError, InstallError) as error:
        code = str(error)
    except KeyboardInterrupt:
        code = "interrupted"
    except Exception:
        # Anything unforeseen still prints a stable code, never a traceback
        # with paths.
        code = "install_failed"
    _fail(code, _INSTALL_EXITS.get(code, EXIT_FAILURE))


def _install(manifest_id: str, env: Mapping[str, str]) -> str:
    """The CLI owns the preflight: platform, then the converter's engines."""
    manifest = load_manifest(manifest_id)
    models = models_dir(env)
    if manifest.apple_silicon_only and not is_apple_silicon():
        raise InstallError("model_unsupported_on_platform")
    # The converter runs in this interpreter; refuse before downloading.
    if manifest.conversion is not None and not all(
        importlib.util.find_spec(name) for name in ("mlx_whisper", "torch")
    ):
        raise InstallError("engine_not_installed")

    def progress(event: str, name: str | None) -> None:
        typer.echo(event if name is None else f"{event} {name}", err=True)

    with httpx.Client(
        trust_env=False, follow_redirects=False, timeout=_DOWNLOAD_TIMEOUT
    ) as client:
        return install(manifest, models, client=client, env=env, progress=progress)
