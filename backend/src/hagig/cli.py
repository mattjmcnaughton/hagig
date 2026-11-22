"""Command-line interface (TDD section 9; PROTOCOL.md, Client rules).

`start` starts or attaches to the server; `status` and `stop` never start one.
`transcribe` reserves a request, decodes the WAV file, uploads canonical audio
and prints only the text on stdout. `uninstall` stops the server and removes
settings, models, logs and runtime files. stderr carries stable codes only. Exit
codes: 0 success (including no speech), 1 failure, 2 usage or configuration
error, 3 busy, 130 interrupted.
"""

import contextlib
import importlib.util
import json
import os
import secrets
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import time
import tomllib
from collections.abc import Generator, Mapping
from pathlib import Path
from typing import Annotated, Any, NoReturn

import httpx
import typer
from pydantic import ValidationError

from hagig.client import Client, Outcome, UnreachableError
from hagig.config import (
    MAX_CONFIG_BYTES,
    Config,
    ConfigError,
    is_apple_silicon,
    load_config,
    validation_issues,
)
from hagig.contract import EXCHANGE_SECONDS, encode_json
from hagig.installer import InstallError, install
from hagig.manifest import (
    MODEL_IDS,
    MODEL_NAMES,
    Manifest,
    ManifestError,
    load_manifest,
)
from hagig.models import INSTALL_LOCK_NAME, ModelError, installed_model
from hagig.paths import (
    LOCK_NAME,
    PathError,
    ServerLock,
    config_file,
    ensure_runtime_dir,
    logs_dir,
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
    """Stop the server and remove settings, models, logs and runtime files.

    The app bundle is left in place; the command prints how to remove it.
    Exit 0 removed, 1 failure or declined.
    """
    env = os.environ
    code = None
    try:
        config = config_file(env).parent
        models = models_dir(env)
        state = logs_dir(env).parent
        runtime = runtime_dir(env)
    except PathError as error:
        code = error.code
    if code is not None:
        _fail(code)
    data = models.parent
    if not yes:
        typer.echo("This stops the Hagig server and permanently removes:")
        for path in (config, data, state, runtime):
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
    _remove(runtime, models, (data, config, state))
    typer.echo("Removed Hagig's settings, models, logs and runtime files.")
    # Never delete the bundle this CLI runs from, under a possibly running app.
    bundle = _app_bundle()
    typer.echo("To finish, quit Hagig, then delete the app and its microphone access:")
    typer.echo(
        f"  rm -rf {shlex.quote(str(bundle))}" if bundle else "  (delete Hagig.app)"
    )
    typer.echo(f"  tccutil reset Microphone {BUNDLE_ID}")


def _remove(runtime: Path, models: Path, directories: tuple[Path, ...]) -> None:
    """Remove `directories`, then runtime, holding the server and install locks.

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
            for path in (*directories, runtime):
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
# How often `--json` reports bytes while one file downloads.
_PROGRESS_SECONDS = 0.25
_JSON = typer.Option("--json", help="Machine-readable JSON lines on stdout.")


def _emit(value: dict[str, Any]) -> None:
    typer.echo(encode_json(value).decode())


@model_app.command("install")
def model_install(manifest_id: str, json_lines: Annotated[bool, _JSON] = False) -> None:
    """Explicitly download, verify and publish a model (the only network step).

    Prints `installed` or `already_installed`. stderr carries progress as
    `<event> [<manifest file>]` and failures as `<code>[: <manifest file>]`.
    With `--json`, stdout instead carries one object per line: progress
    `{"event", "file", "received", "total"}` (bytes over every download) and
    then `{"event": "done", "result"}`; failures stay on stderr.
    Exit 0 success, 1 failure, 2 unknown or unsupported model, 130 interrupted.
    """
    try:
        result = _install(manifest_id, os.environ, json_lines)
        if json_lines:
            _emit({"event": "done", "result": result})
        else:
            typer.echo(result)
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


def _preflight(manifest: Manifest) -> None:
    """What this machine needs before installing or using a model."""
    if manifest.apple_silicon_only and not is_apple_silicon():
        raise InstallError("model_unsupported_on_platform")
    # The converter runs in this interpreter; refuse before downloading.
    if manifest.conversion is not None and not all(
        importlib.util.find_spec(name) for name in ("mlx_whisper", "torch")
    ):
        raise InstallError("engine_not_installed")


def _download_bytes(manifest: Manifest) -> int:
    converter = manifest.conversion.size if manifest.conversion is not None else 0
    return sum(entry.size for entry in manifest.files) + converter


def _install(manifest_id: str, env: Mapping[str, str], json_lines: bool) -> str:
    """The CLI owns the preflight: platform, then the converter's engines."""
    manifest = load_manifest(manifest_id)
    models = models_dir(env)
    _preflight(manifest)
    total = _download_bytes(manifest)
    finished = 0  # bytes of the downloads already complete
    current = 0  # bytes of the one in progress
    reported = 0.0
    name: str | None = None

    def report() -> None:
        _emit(
            {
                "event": event,
                "file": name,
                "received": finished + current,
                "total": total,
            }
        )

    def progress(next_event: str, next_name: str | None) -> None:
        nonlocal event, name, finished, current, reported
        if not json_lines:
            typer.echo(
                next_event if next_name is None else f"{next_event} {next_name}",
                err=True,
            )
            return
        event, name = next_event, next_name
        finished, current, reported = finished + current, 0, time.monotonic()
        report()

    def received(count: int) -> None:
        nonlocal current, reported
        current = count
        if json_lines and time.monotonic() - reported >= _PROGRESS_SECONDS:
            reported = time.monotonic()
            report()

    event = "verify"
    with httpx.Client(
        trust_env=False, follow_redirects=False, timeout=_DOWNLOAD_TIMEOUT
    ) as client:
        return install(
            manifest,
            models,
            client=client,
            env=env,
            progress=progress,
            received=received,
        )


@model_app.command("list")
def model_list(json_output: Annotated[bool, _JSON] = False) -> None:
    """List the models Hagig can install, and which are installed and in use.

    Offline and read-only: the tracked manifests, a cheap check of each
    installation (no hashing) and the settings file's `model.id`. With
    `--json`, one object: `configured` (an ID or null), `config_issue` (a
    stable code when a settings file exists but is invalid, else null) and
    `models`, each with `id`, `name`, `engine`, `publisher`, `repository`,
    `license`, `download_bytes`, `supported` and `installed` (`installed`,
    `missing` or `invalid`).
    """
    env = os.environ
    code = None
    try:
        models = models_dir(env)
        path = config_file(env)
    except PathError as error:
        code = error.code
    if code is not None:
        _fail(code)
    configured, issue = _configured(path)
    entries: list[dict[str, Any]] = []
    for manifest_id in MODEL_IDS:
        manifest = load_manifest(manifest_id)
        try:
            installed_model(models, manifest)
            state = "installed"
        except ModelError as error:
            state = "missing" if error.code == "model_missing" else "invalid"
        try:
            _preflight(manifest)
            supported = True
        except InstallError:
            supported = False
        entries.append(
            {
                "id": manifest.id,
                "name": MODEL_NAMES.get(manifest.id, manifest.id),
                "engine": manifest.engine,
                "publisher": manifest.source.publisher,
                "repository": manifest.source.repository,
                "license": manifest.source.license,
                "download_bytes": _download_bytes(manifest),
                "supported": supported,
                "installed": state,
            }
        )
    if json_output:
        _emit({"configured": configured, "config_issue": issue, "models": entries})
        return
    for entry in entries:
        marks = [entry["installed"]]
        if entry["id"] == configured:
            marks.append("in use")
        if not entry["supported"]:
            marks.append("unsupported")
        typer.echo(f"{entry['id']}\t{', '.join(marks)}")


def _configured(path: Path) -> tuple[str | None, str | None]:
    """The settings file's model, or the stable code that stops it loading."""
    try:
        return load_config(path).model.id, None
    except ConfigError as error:
        failure = str(error)
    return None, (failure if os.path.lexists(path) else None)


settings_app = typer.Typer(no_args_is_help=True)
app.add_typer(settings_app, name="settings", help="Read and change settings.")

# Every setting, as `settings show --json` reports it and `settings set` takes it.
_SETTING_KEYS = (
    "model_id",
    "editor_mode",
    "network_isolation",
    "vocabulary",
    "record_shortcut",
    "cancel_shortcut",
    "copy_shortcut",
    "dismiss_shortcut",
)


def _settings_of(config: Config) -> dict[str, Any]:
    return {
        "model_id": config.model.id,
        "editor_mode": config.editor.mode,
        "network_isolation": config.inference.network_isolation,
        "vocabulary": list(config.vocabulary.terms),
        "record_shortcut": config.shortcuts.record,
        "cancel_shortcut": config.shortcuts.cancel,
        "copy_shortcut": config.shortcuts.copy_all,
        "dismiss_shortcut": config.shortcuts.dismiss,
    }


def _settings_path(env: Mapping[str, str]) -> Path:
    code = None
    try:
        return config_file(env)
    except PathError as error:
        code = error.code
    _fail(code)


@settings_app.command("show")
def settings_show() -> None:
    """Print the settings file as one JSON object (offline, read-only).

    `path`, `exists`, `issue` (a stable code when the file does not load, else
    null), `settings` (`model_id`, `editor_mode`, `network_isolation`,
    `vocabulary` and the `record`, `cancel`, `copy` and `dismiss` `_shortcut`s,
    with defaults filled in; null when the file does not load) and `logs_dir`,
    the logs directory (computed, not created), so the app needs no path rules
    of its own.
    """
    path = _settings_path(os.environ)
    # Same base rules as the settings path, which has just been computed.
    logs = logs_dir(os.environ)
    config = None
    issue = None
    try:
        config = load_config(path)
    except ConfigError as error:
        issue = str(error)
    exists = os.path.lexists(path)
    _emit(
        {
            "path": str(path),
            "exists": exists,
            # A missing file is not a problem to report, only an empty choice.
            "issue": issue if exists else None,
            "settings": _settings_of(config) if config is not None else None,
            "logs_dir": str(logs),
        }
    )


@settings_app.command("set")
def settings_set(
    replace: Annotated[
        bool,
        typer.Option("--replace", help="Replace a settings file that does not load."),
    ] = False,
) -> None:
    """Change settings from a JSON object on stdin, then rewrite the file.

    The object holds any of `model_id`, `editor_mode`, `network_isolation`,
    `vocabulary` (a list of strings), `record_shortcut`, `cancel_shortcut`,
    `copy_shortcut` and `dismiss_shortcut`;
    missing keys keep their current values.
    Input travels on stdin so vocabulary never appears in a process list. The
    merged settings are validated exactly as the server will load them, then
    written atomically (0600). A file that does not load is refused
    (`config_unloadable`) unless `--replace`. Comments in the file are not
    kept. A model must be installed first (`model_missing`); nothing is ever
    downloaded. A running server keeps the settings it started with, so an
    idle one is stopped and the next request starts it with these; a busy one
    refuses (`busy`, exit 3) before anything is written. Prints `updated` or
    `unchanged`. Failures are stable codes and field names, never values.
    """
    env = os.environ
    path = _settings_path(env)
    changes = _read_changes()
    current: dict[str, Any] = {}
    exists = os.path.lexists(path)
    if exists:
        try:
            current = _settings_of(load_config(path))
        except ConfigError:
            if not replace:
                _fail(f"config_unloadable: fix or replace {path}")
    merged = {**current, **changes}
    if "model_id" not in merged:
        _fail("config_invalid: model.id missing", EXIT_USAGE)
    document = _toml(merged)
    code = None
    try:
        # Exactly the server's validation, on exactly the bytes to be written.
        config = Config.model_validate(
            tomllib.loads(document.decode()),
            context={"apple_silicon": is_apple_silicon()},
        )
        manifest = load_manifest(config.model.id)
        installed_model(models_dir(env), manifest)
    except ValidationError as error:
        code = str(ConfigError("config_invalid", validation_issues(error)))
    except (ManifestError, ModelError, PathError) as error:
        code = str(error)
    if code is not None:
        _fail(code, EXIT_USAGE if code.startswith("config_invalid") else EXIT_FAILURE)
    if exists and current == _settings_of(config):
        typer.echo("unchanged")
        return
    runtime, sock = _runtime(env)
    with Client(sock) as client:
        try:
            outcome: Outcome | None = client.status()
        except UnreachableError:
            outcome = None
    if outcome is not None and outcome.kind != "compatible":
        _report(outcome)
    if outcome is not None and outcome.data["state"] != "idle":
        _fail("busy", EXIT_BUSY)
    _write(path, document)
    if outcome is not None:
        _stop_server(runtime, sock)
    typer.echo("updated")


def _read_changes() -> dict[str, Any]:
    raw = sys.stdin.buffer.read(MAX_CONFIG_BYTES + 1)
    changes: Any = None
    with contextlib.suppress(ValueError):
        changes = json.loads(raw) if len(raw) <= MAX_CONFIG_BYTES else None
    if isinstance(changes, dict) and set(changes) <= set(_SETTING_KEYS):
        # Only strings reach the TOML writer; values are validated after.
        vocabulary = changes.get("vocabulary", [])
        scalars = [v for k, v in changes.items() if k != "vocabulary"]
        if isinstance(vocabulary, list) and all(
            isinstance(text, str) for text in [*scalars, *vocabulary]
        ):
            return changes
    _fail("settings_input_invalid", EXIT_USAGE)


def _toml(settings: dict[str, Any]) -> bytes:
    """TOML for settings whose values are strings or lists of strings.

    `json.dumps` with non-ASCII kept is a TOML basic string: it escapes only
    quotes, backslashes and control characters, which TOML decodes back, and
    which validation then rejects in vocabulary.
    """

    def value(item: Any) -> str:
        if isinstance(item, list):
            return "[" + ", ".join(value(term) for term in item) + "]"
        return json.dumps(item, ensure_ascii=False)

    lines = [f"[model]\nid = {value(settings['model_id'])}"]
    if "editor_mode" in settings:
        lines.append(f"[editor]\nmode = {value(settings['editor_mode'])}")
    if "network_isolation" in settings:
        lines.append(
            f"[inference]\nnetwork_isolation = {value(settings['network_isolation'])}"
        )
    if "vocabulary" in settings:
        lines.append(f"[vocabulary]\nterms = {value(settings['vocabulary'])}")
    shortcuts = [
        f"{name} = {value(settings[f'{name}_shortcut'])}"
        for name in ("record", "cancel", "copy", "dismiss")
        if f"{name}_shortcut" in settings
    ]
    if shortcuts:
        lines.append("\n".join(["[shortcuts]", *shortcuts]))
    return ("\n\n".join(lines) + "\n").encode()


def _write(path: Path, document: bytes) -> None:
    code = None
    temporary: Path | None = None
    try:
        path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
        temporary = path.with_name(f".config-{secrets.token_hex(8)}.toml")
        fd = os.open(
            temporary,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
            0o600,
        )
        with os.fdopen(fd, "wb") as out:
            out.write(document)
            out.flush()
            os.fsync(out.fileno())
        os.replace(temporary, path)
        temporary = None
    except OSError:
        code = "config_write_failed"
    finally:
        if temporary is not None:
            with contextlib.suppress(OSError):
                os.unlink(temporary)
    if code is not None:
        _fail(code)
