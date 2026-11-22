"""The real `hagig` CLI against the test server, and against the real server."""

import importlib.util
import json
import os
import platform
import shutil
import signal
import subprocess
import sys
import tomllib
import wave
from pathlib import Path

import pytest

from hagig.paths import ServerLock
from hagig.wav import read_wav
from tests.support.harness import pid_alive, wait_for
from tests.support.models import private_models_dir

HAGIG = str(Path(sys.executable).parent / "hagig")
SPEECH = Path(__file__).parents[1] / "fixtures" / "speech.wav"


def hagig(home, *args, timeout=60):
    return subprocess.run(
        [HAGIG, *args], env=home.env, capture_output=True, timeout=timeout
    )


def wav_copy(home):
    path = home.root / "input.wav"
    shutil.copyfile(SPEECH, path)
    os.utime(path, (1_000_000_000, 1_000_000_000))
    return path


def test_transcribe_prints_only_the_text_and_leaves_the_input_unchanged(server):
    path = wav_copy(server)
    before = (path.read_bytes(), path.stat().st_mtime_ns)
    server.engine(text="Fixture λ.\nNext line.")
    result = hagig(server, "transcribe", str(path))
    assert (result.returncode, result.stdout, result.stderr) == (
        0,
        "Fixture λ.\nNext line.\n".encode(),
        b"",
    )
    assert (path.read_bytes(), path.stat().st_mtime_ns) == before
    # The engine received the decoded canonical audio, exactly.
    expected = read_wav(path).astype("<f4").tobytes()
    assert server.record("audio", server.pids()[-1], ".bin") == expected


def test_no_speech_succeeds_with_empty_stdout(server):
    for text in ["", " \n\t "]:
        server.engine(text=text)
        result = hagig(server, "transcribe", str(wav_copy(server)))
        assert (result.returncode, result.stdout, result.stderr) == (0, b"", b"")


def test_a_silent_wav_is_no_speech_without_a_worker(server):
    path = server.root / "silent.wav"
    with wave.open(str(path), "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(16000)
        out.writeframes(bytes(2 * 16000))
    server.engine(text="Fixture.")
    result = hagig(server, "transcribe", str(path))
    assert (result.returncode, result.stdout, result.stderr) == (0, b"", b"")
    assert server.pids() == []


def test_an_echo_of_the_vocabulary_is_no_speech(server):
    server.engine(text="Vocabulary: Hagig, Ghostty-secret-term.")
    result = hagig(server, "transcribe", str(wav_copy(server)))
    assert (result.returncode, result.stdout, result.stderr) == (0, b"", b"")
    # speech.wav is audible, so the engine ran and its echo was dropped.
    assert len(server.pids()) == 1


def test_busy_exits_3(server):
    server.admit()
    result = hagig(server, "transcribe", str(wav_copy(server)))
    assert (result.returncode, result.stdout, result.stderr) == (3, b"", b"busy\n")


def test_worker_failure_exits_1_with_a_stable_code(server):
    server.engine(behavior="crash")
    result = hagig(server, "transcribe", str(wav_copy(server)))
    assert (result.returncode, result.stdout, result.stderr) == (
        1,
        b"",
        b"worker_failed\n",
    )


def test_bad_wav_exits_2_and_releases_the_reservation(server):
    path = server.root / "bad.wav"
    path.write_bytes(b"RIFF secret-looking content")
    result = hagig(server, "transcribe", str(path))
    assert (result.returncode, result.stdout) == (2, b"")
    assert result.stderr == b"wav_malformed\n"
    assert server.status()["state"] == "idle"
    assert server.pids() == []


def interruptible(home, *args):
    # The caller's shell may ignore SIGINT, which a child would inherit.
    return subprocess.Popen(
        [HAGIG, *args],
        env=home.env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        preexec_fn=lambda: signal.signal(signal.SIGINT, signal.SIG_DFL),
    )


def test_ctrl_c_cancels_and_exits_130(server):
    server.engine(behavior="stall")
    process = interruptible(server, "transcribe", str(wav_copy(server)))
    pid = wait_for(server.computing)[0]
    process.send_signal(signal.SIGINT)
    stdout, stderr = process.communicate(timeout=30)
    assert (process.returncode, stdout, stderr) == (130, b"", b"")
    wait_for(lambda: not pid_alive(pid), timeout=5)
    server.wait_idle(timeout=5)


def test_ctrl_c_before_the_upload_releases_the_reservation_at_once(server):
    # A FIFO with no writer blocks the WAV read after admission, before any
    # upload connection exists, so only the DELETE can end the reservation.
    fifo = server.root / "input.wav"
    os.mkfifo(fifo)
    process = interruptible(server, "transcribe", str(fifo))
    # Busy as soon as the server admits, which may be before the CLI has read
    # the 201; the CLI must cancel either way.
    wait_for(lambda: server.status()["state"] == "busy")
    process.send_signal(signal.SIGINT)
    stdout, stderr = process.communicate(timeout=30)
    assert (process.returncode, stdout, stderr) == (130, b"", b"")
    # The CLI exits only after its DELETE is answered, so the slot is already
    # free: no wait, and nowhere near the 5 s upload-start deadline.
    assert server.status()["state"] == "idle"
    assert server.pids() == []


def test_status_and_stop_never_start_a_server(home):
    home.write_config()
    assert hagig(home, "status").stdout == b"stopped\n"
    stopped = hagig(home, "stop")
    assert (stopped.returncode, stopped.stdout, stopped.stderr) == (0, b"", b"")
    assert not home.socket.exists()


def test_missing_model_id_is_actionable_and_content_free(home):
    home.config_path.parent.mkdir(parents=True)
    home.config_path.write_text('[vocabulary]\nterms = ["private-term"]\n')
    result = hagig(home, "transcribe", str(wav_copy(home)))
    assert result.returncode == 2
    assert result.stdout == b""
    message = result.stderr.decode()
    assert "set [model] id in" in message
    assert str(home.config_path) in message
    assert "private-term" not in message
    assert not home.socket.exists()


@pytest.mark.parametrize(
    ("model", "stderr"),
    [
        ("qwen3-asr-9b", b"unknown_model\n"),
        ("../qwen3-asr-0.6b", b"unknown_model\n"),
        pytest.param(
            "whisper-large-v3-turbo",
            b"model_unsupported_on_platform\n",
            marks=pytest.mark.skipif(
                sys.platform == "darwin" and platform.machine() == "arm64",
                reason="Whisper installs on Apple Silicon",
            ),
        ),
    ],
)
def test_model_install_refuses_before_any_download(home, model, stderr):
    result = hagig(home, "model", "install", model)
    assert (result.returncode, result.stdout, result.stderr) == (2, b"", stderr)
    assert not (home.root / "data").exists()


def test_model_install_failures_are_stable_codes_before_any_download(home):
    models = home.root / "data" / "hagig" / "models"
    private_models_dir(models)
    # Another install holds the persistent lock.
    lock = ServerLock.acquire(models, name=".install.lock")
    assert lock is not None
    try:
        held = hagig(home, "model", "install", "qwen3-asr-0.6b")
    finally:
        lock.release()
    assert (held.returncode, held.stdout, held.stderr) == (
        1,
        b"",
        b"install_in_progress\n",
    )
    models.chmod(0o777)
    unsafe = hagig(home, "model", "install", "qwen3-asr-0.6b")
    assert (unsafe.returncode, unsafe.stdout, unsafe.stderr) == (
        1,
        b"",
        b"model_dir_unsafe\n",
    )
    assert sorted(p.name for p in models.iterdir()) == [".install.lock"]


@pytest.mark.skipif(
    not (sys.platform == "darwin" and platform.machine() == "arm64")
    or importlib.util.find_spec("mlx_whisper") is not None,
    reason="needs Apple Silicon without the mlx-whisper extra",
)
def test_whisper_install_without_the_engine_refuses_before_downloading(home):
    result = hagig(home, "model", "install", "whisper-large-v3-turbo")
    assert (result.returncode, result.stdout, result.stderr) == (
        1,
        b"",
        b"engine_not_installed\n",
    )
    assert not (home.root / "data").exists()


def test_real_server_refuses_an_unmatched_installation_then_stops(home):
    home.write_config()
    home.install_model()
    starts = [
        subprocess.Popen([HAGIG, "start"], env=home.env, stderr=subprocess.PIPE)
        for _ in range(3)
    ]
    # Concurrent starts all attach to the one winner.
    assert [p.wait(timeout=30) for p in starts] == [0, 0, 0]
    status = hagig(home, "status")
    assert status.returncode == 0
    assert b'"network_isolation":"disabled"' in status.stdout
    assert b'"worker":"absent"' in status.stdout

    # The CLI-spawned server checks the tracked manifest, which the harness's
    # small synthetic installation cannot match, so each request fails before
    # any worker launches (the worker path is covered with the fake engine).
    for _ in range(2):
        result = hagig(home, "transcribe", str(wav_copy(home)))
        assert (result.returncode, result.stdout, result.stderr) == (
            1,
            b"",
            b"model_invalid\n",
        )
    assert b'"state":"idle","worker":"absent"' in hagig(home, "status").stdout

    stopped = hagig(home, "stop")
    assert (stopped.returncode, stopped.stderr) == (0, b"")
    assert not home.socket.exists()
    lock = ServerLock.acquire(home.runtime)
    assert lock is not None
    lock.release()
    assert hagig(home, "status").stdout == b"stopped\n"


def test_uninstall_stops_the_server_and_removes_every_directory(server):
    process = server.servers[0]
    data, config = server.models.parent, server.config_path.parent
    assert data.is_dir() and config.is_dir() and server.runtime.is_dir()
    result = hagig(server, "uninstall", "--yes")
    assert (result.returncode, result.stderr) == (0, b"")
    assert b"tccutil reset Microphone com.mattjmcnaughton.hagig" in result.stdout
    assert process.wait(timeout=5) == 0
    # The data directory holds the models; the runtime directory the kept lock.
    assert not data.exists()
    assert not config.exists()
    assert not server.runtime.exists()
    # Only Hagig's own directories: the XDG bases stay.
    assert data.parent.is_dir() and config.parent.is_dir()
    assert hagig(server, "status").stdout == b"stopped\n"


def test_declining_uninstall_changes_nothing(server):
    before = sorted(p for p in server.root.rglob("*") if "control" not in p.parts)
    result = subprocess.run(
        [HAGIG, "uninstall"],
        env=server.env,
        input=b"n\n",
        capture_output=True,
        timeout=60,
    )
    assert (result.returncode, result.stderr) == (1, b"cancelled\n")
    # The prompt names all three directories, including the computed runtime one.
    for path in (server.config_path.parent, server.models.parent, server.runtime):
        assert f"  {path}\n".encode() in result.stdout
    assert (
        sorted(p for p in server.root.rglob("*") if "control" not in p.parts) == before
    )
    assert server.status()["state"] == "idle"


# The model registry and settings: `model list` and `settings show|set`.


def tracked_installation(home, model_id):
    """A tracked manifest's installation as the cheap check sees it.

    Sparse files at the recorded sizes: `installed_model` never hashes, so this
    stands in for gigabytes of weights without writing them.
    """
    from hagig.manifest import load_manifest

    manifest = load_manifest(model_id)
    version = "v-" + "1" * 32
    base = home.models / model_id
    target = base / version
    for directory in (home.models, base, target):
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    files = {f.path: (f.size, f.sha256) for f in manifest.files}
    for name, (size, _digest) in files.items():
        with open(target / name, "wb") as out:
            out.truncate(size)
    record = {
        "format": 1,
        "manifest": manifest.id,
        "manifest_sha256": manifest.digest,
        "files": [
            {"path": n, "size": s, "sha256": d} for n, (s, d) in sorted(files.items())
        ],
    }
    (target / "hagig-install.json").write_text(json.dumps(record))
    os.symlink(version, base / "current")


def listed(home):
    result = hagig(home, "model", "list", "--json")
    assert result.returncode == 0, result.stderr
    assert result.stdout.count(b"\n") == 1
    return json.loads(result.stdout)


def test_model_list_reports_the_whole_registry_offline(home):
    data = listed(home)
    assert data["configured"] is None and data["config_issue"] is None
    ids = [m["id"] for m in data["models"]]
    assert ids == ["qwen3-asr-0.6b", "qwen3-asr-1.7b", "whisper-large-v3-turbo"]
    by_id = {m["id"]: m for m in data["models"]}
    assert {m["installed"] for m in data["models"]} == {"missing"}
    # Sizes from the manifests themselves, summed independently here.
    qwen = json.loads(
        (Path(hagig_pkg_dir()) / "manifests" / "qwen3-asr-0.6b.json").read_text()
    )
    assert by_id["qwen3-asr-0.6b"]["download_bytes"] == sum(
        f["size"] for f in qwen["files"]
    )
    assert by_id["whisper-large-v3-turbo"]["engine"] == "mlx-whisper"
    apple = sys.platform == "darwin" and platform.machine() == "arm64"
    if not apple:
        assert by_id["whisper-large-v3-turbo"]["supported"] is False
    assert by_id["qwen3-asr-1.7b"]["supported"] is True
    # Listing reads; it creates nothing.
    assert not (home.root / "data").exists()


def hagig_pkg_dir():
    import hagig

    return Path(hagig.__file__).parent


def test_model_list_shows_installed_invalid_and_configured(home):
    tracked_installation(home, "qwen3-asr-1.7b")
    (home.models / "qwen3-asr-0.6b").mkdir(mode=0o700)
    os.symlink("not-a-version", home.models / "qwen3-asr-0.6b" / "current")
    home.config_path.parent.mkdir(parents=True)
    home.config_path.write_text('[model]\nid = "qwen3-asr-1.7b"\n')
    data = listed(home)
    states = {m["id"]: m["installed"] for m in data["models"]}
    assert states == {
        "qwen3-asr-0.6b": "invalid",
        "qwen3-asr-1.7b": "installed",
        "whisper-large-v3-turbo": "missing",
    }
    assert data["configured"] == "qwen3-asr-1.7b"
    # A broken settings file is reported by code, never by content.
    home.config_path.write_text('[model]\nid = "private-secret"\n')
    data = listed(home)
    assert data["configured"] is None
    assert data["config_issue"] == "config_invalid: model.id invalid_value"


def settings_set(home, changes, *args):
    return subprocess.run(
        [HAGIG, "settings", "set", *args],
        env=home.env,
        input=json.dumps(changes).encode(),
        capture_output=True,
        timeout=60,
    )


def shown(home):
    result = hagig(home, "settings", "show")
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)


def test_settings_set_writes_a_first_settings_file_the_server_accepts(home):
    assert shown(home) == {
        "path": str(home.config_path),
        "exists": False,
        "issue": None,
        "settings": None,
    }
    tracked_installation(home, "qwen3-asr-1.7b")
    terms = ['Quote " and \\ back', "日本語 😀", "Ghostty"]
    result = settings_set(
        home,
        {"model_id": "qwen3-asr-1.7b", "editor_mode": "vim", "vocabulary": terms},
    )
    assert (result.returncode, result.stdout, result.stderr) == (0, b"updated\n", b"")
    assert home.config_path.stat().st_mode & 0o777 == 0o600
    # Read back independently with the stdlib parser, then by the backend.
    with open(home.config_path, "rb") as handle:
        written = tomllib.load(handle)
    assert written == {
        "model": {"id": "qwen3-asr-1.7b"},
        "editor": {"mode": "vim"},
        "vocabulary": {"terms": terms},
    }
    assert shown(home)["settings"] == {
        "model_id": "qwen3-asr-1.7b",
        "editor_mode": "vim",
        "network_isolation": "required",
        "vocabulary": terms,
        "record_shortcut": "ctrl+option+space",
        "cancel_shortcut": "ctrl+option+escape",
    }
    # A partial change keeps the rest; the same values again change nothing.
    isolation = settings_set(home, {"network_isolation": "disabled"})
    assert isolation.stdout == b"updated\n"
    assert shown(home)["settings"]["vocabulary"] == terms
    assert settings_set(home, {"editor_mode": "vim"}).stdout == b"unchanged\n"


def test_settings_set_refuses_without_writing(home):
    tracked_installation(home, "qwen3-asr-1.7b")
    missing = settings_set(home, {"model_id": "qwen3-asr-0.6b"})
    assert (missing.returncode, missing.stderr) == (1, b"model_missing\n")
    no_model = settings_set(home, {"editor_mode": "vim"})
    assert (no_model.returncode, no_model.stderr) == (
        2,
        b"config_invalid: model.id missing\n",
    )
    secret = "private\nterm"
    bad = settings_set(home, {"model_id": "qwen3-asr-1.7b", "vocabulary": [secret]})
    assert (bad.returncode, bad.stderr) == (
        2,
        b"config_invalid: vocabulary.terms[0] invalid_value\n",
    )
    for wrong in [{"model_id": 5}, {"other": "x"}, {"vocabulary": "one"}, []]:
        refused = settings_set(home, wrong)
        assert (refused.returncode, refused.stderr) == (2, b"settings_input_invalid\n")
    assert not home.config_path.exists()


def test_settings_set_round_trips_shortcuts_and_refuses_bad_ones(home):
    tracked_installation(home, "qwen3-asr-1.7b")
    result = settings_set(
        home,
        {
            "model_id": "qwen3-asr-1.7b",
            "record_shortcut": "cmd+shift+space",
            "cancel_shortcut": "cmd+shift+escape",
        },
    )
    assert (result.returncode, result.stdout, result.stderr) == (0, b"updated\n", b"")
    with open(home.config_path, "rb") as handle:
        written = tomllib.load(handle)
    assert written == {
        "model": {"id": "qwen3-asr-1.7b"},
        "shortcuts": {"record": "cmd+shift+space", "cancel": "cmd+shift+escape"},
    }
    settings = shown(home)["settings"]
    assert (settings["record_shortcut"], settings["cancel_shortcut"]) == (
        "cmd+shift+space",
        "cmd+shift+escape",
    )
    # A change to one shortcut keeps the other and every other setting.
    assert settings_set(home, {"cancel_shortcut": "f12+ctrl"}).stdout == b"updated\n"
    settings = shown(home)["settings"]
    assert settings["record_shortcut"] == "cmd+shift+space"
    assert settings["cancel_shortcut"] == "f12+ctrl"
    before = home.config_path.read_bytes()
    secret = "ctrl+private-secret"
    bad = settings_set(home, {"record_shortcut": secret})
    assert (bad.returncode, bad.stderr) == (
        2,
        b"config_invalid: shortcuts.record invalid_value\n",
    )
    same = settings_set(home, {"record_shortcut": "ctrl+f12"})
    assert (same.returncode, same.stderr) == (
        2,
        b"config_invalid: shortcuts.cancel invalid_value\n",
    )
    assert settings_set(home, {"record_shortcut": 5}).returncode == 2
    assert home.config_path.read_bytes() == before


def test_an_unloadable_settings_file_is_replaced_only_when_asked(home):
    tracked_installation(home, "qwen3-asr-1.7b")
    home.config_path.parent.mkdir(parents=True)
    home.config_path.write_text("[model\nid = 'private-secret'\n")
    before = home.config_path.read_bytes()
    assert shown(home)["issue"] == "config_syntax"
    refused = settings_set(home, {"model_id": "qwen3-asr-1.7b"})
    assert refused.returncode == 1
    assert refused.stderr.startswith(b"config_unloadable: fix or replace ")
    assert b"private-secret" not in refused.stderr
    assert home.config_path.read_bytes() == before
    replaced = settings_set(home, {"model_id": "qwen3-asr-1.7b"}, "--replace")
    assert replaced.stdout == b"updated\n"
    assert shown(home)["issue"] is None


def test_settings_set_stops_an_idle_server_and_refuses_a_busy_one(server):
    tracked_installation(server, "qwen3-asr-1.7b")
    server.config_path.write_text('[model]\nid = "qwen3-asr-0.6b"\n')
    request = server.admit()
    busy = settings_set(server, {"model_id": "qwen3-asr-1.7b"})
    assert (busy.returncode, busy.stderr) == (3, b"busy\n")
    assert server.config_path.read_text() == '[model]\nid = "qwen3-asr-0.6b"\n'
    with server.client() as client:
        assert client.delete(f"/v1/requests/{request}").status_code == 204
    used = settings_set(server, {"model_id": "qwen3-asr-1.7b"})
    assert (used.returncode, used.stdout, used.stderr) == (0, b"updated\n", b"")
    # The server held the old settings, so it was stopped for the next start.
    assert not server.socket.exists()
    assert hagig(server, "status").stdout == b"stopped\n"


def test_model_install_json_refuses_with_codes_on_stderr(home):
    result = hagig(home, "model", "install", "qwen3-asr-9b", "--json")
    assert (result.returncode, result.stdout, result.stderr) == (
        2,
        b"",
        b"unknown_model\n",
    )
