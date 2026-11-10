"""The real `hagig` CLI against the test server, and against the real server."""

import os
import shutil
import signal
import subprocess
import sys
from pathlib import Path

from hagig.paths import ServerLock
from hagig.wav import read_wav
from tests.support.harness import pid_alive, wait_for

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
    wait_for(lambda: server.status()["state"] == "busy")
    process.send_signal(signal.SIGINT)
    stdout, stderr = process.communicate(timeout=30)
    assert (process.returncode, stdout, stderr) == (130, b"", b"")
    # Well inside the 5 s upload-start deadline.
    server.wait_idle(timeout=1)
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


def test_real_server_spawn_attach_worker_restart_and_stop(home):
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

    # The real worker has no real engine yet (#49), so loading fails cleanly,
    # and each request lazily launches a fresh worker.
    for _ in range(2):
        result = hagig(home, "transcribe", str(wav_copy(home)))
        assert (result.returncode, result.stdout, result.stderr) == (
            1,
            b"",
            b"worker_failed\n",
        )
    assert b'"state":"idle","worker":"absent"' in hagig(home, "status").stdout

    stopped = hagig(home, "stop")
    assert (stopped.returncode, stopped.stderr) == (0, b"")
    assert not home.socket.exists()
    lock = ServerLock.acquire(home.runtime)
    assert lock is not None
    lock.release()
    assert hagig(home, "status").stdout == b"stopped\n"
