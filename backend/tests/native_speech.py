"""Opt-in real candidate check, not model-quality/privacy adoption or app testing.

Requires an already prepared Contents/{Helpers,Frameworks} and verified model
under ROOT/data. No network acquisition or fake peer exists in this harness.
speech.wav is synthetic flite/kal: "Open the project and run the tests", generated
with ffmpeg -f lavfi -i 'flite=text=Open the project and run the tests:voice=kal'
-ar 16000 -ac 1 -c:a pcm_s16le speech.wav. No personal recording or new TTS asset.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time
import wave


def digest(path):
    with path.open("rb") as source:
        checksum = hashlib.sha256()
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            checksum.update(chunk)
        return checksum.hexdigest()


def ps(pid, field):
    return subprocess.check_output(
        ["/bin/ps", "-p", str(pid), "-o", field + "="], timeout=5, text=True
    ).strip()


def exists(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def threads(pid):
    if sys.platform == "darwin":
        # macOS ps -M prints one row per thread; omit the header.
        return len(subprocess.check_output(
            ["/bin/ps", "-M", "-p", str(pid), "-o", "pid="],
            timeout=5, text=True
        ).splitlines())
    return len(list(Path(f"/proc/{pid}/task").iterdir()))


def cpu_seconds(pid):
    if sys.platform != "darwin":
        fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
        return (int(fields[11]) + int(fields[12])) / os.sysconf("SC_CLK_TCK")
    total = 0.0
    for part in ps(pid, "time").split(":"):
        total = total * 60 + float(part)
    return total


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--root", type=Path, required=True)
parser.add_argument("--mode", choices=["required", "disabled"], default="required")
args = parser.parse_args()
root = args.root.resolve(strict=True)
exe = root / "Contents/Helpers/hagig"
speech = Path(__file__).parent / "fixtures/speech.wav"
assert digest(speech) == "1195f9a86dc5be10874555ebf29d37865dd3b4ef2bff8caa4fedf9a02cd92224"
env = {k: v for k, v in os.environ.items() if not k.startswith(("DYLD_", "LD_"))}
env["XDG_DATA_HOME"] = str(root / "data")


def call(*command):
    return subprocess.run([str(exe), *map(str, command)], env=env,
                          capture_output=True, timeout=150)


class SpeechMismatch(Exception):
    """The sole expected semantic outcome of the zero-PCM control."""


def assert_speech(text):
    words = set(re.findall(r"[a-z]+", text.decode().lower()))
    if not {"open", "project", "run"} <= words:
        raise SpeechMismatch(f"supplied speech not distinguished: {text!r}")
    assert text.endswith(b"\n")
    # These known quality failures are observations, not passing acceptance.
    print("PLURAL_TESTS", "PASS" if "tests" in words else "UNPROVEN: plural tests missing", flush=True)


mismatch = None
with tempfile.TemporaryDirectory(prefix="hg9-speech-", dir="/tmp") as temporary:
    runtime = Path(temporary)
    runtime.chmod(0o700)
    env["XDG_RUNTIME_DIR"] = str(runtime)
    env["XDG_CONFIG_HOME"] = str(runtime / "config")
    config = runtime / "config/hagig"
    config.mkdir(parents=True)
    (config / "config.toml").write_text(f"[inference]\nnetwork_isolation='{args.mode}'\n")
    with wave.open(str(speech)) as source:
        assert (source.getnchannels(), source.getsampwidth(), source.getframerate()) == (1, 2, 16000)
        samples = source.readframes(source.getnframes())
    silence, long_audio = runtime / "silence.wav", runtime / "long.wav"
    for path, pcm in [(silence, bytes(64000)),
                      (long_audio, (samples * (1920000 // len(samples) + 1))[:1920000])]:
        with wave.open(str(path), "wb") as output:
            output.setnchannels(1)
            output.setsampwidth(2)
            output.setframerate(16000)
            output.writeframes(pcm)
    inputs = {path: digest(path) for path in (speech, silence, long_audio)}
    server = subprocess.Popen([str(exe), "__serve"], env=env,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    client = None
    owned_workers = set()
    try:
        deadline = time.monotonic() + 8
        while not (runtime / "hagig/server.sock").exists():
            assert server.poll() is None, "server exited before ready"
            assert time.monotonic() < deadline, "server startup deadline"
            time.sleep(.01)

        def status():
            result = call("status")
            assert result.returncode == 0, result
            value = json.loads(result.stdout)
            assert value["server_pid"] == server.pid
            assert value["worker"] == "inference" and value["network_isolation"] == args.mode
            return value

        def transcribe(path):
            result = call("transcribe", path)
            assert result.returncode == 0 and result.stderr == b"", result
            print("SYNTHETIC", path.name, repr(result.stdout), flush=True)
            return result.stdout

        def worker():
            pid = status()["worker_pid"]
            assert isinstance(pid, int) and int(ps(pid, "ppid")) == server.pid
            owned_workers.add(pid)
            return pid

        def idle_and_reaped(pid):
            deadline = time.monotonic() + 8
            while status()["state"] != "idle":
                assert time.monotonic() < deadline, "cleanup deadline"
                time.sleep(.01)
            assert not exists(pid), "native child not reaped"

        def active_request(pid):
            idle_threads = threads(server.pid)
            old_cpu = cpu_seconds(pid)
            pending = subprocess.Popen([str(exe), "transcribe", str(long_audio)], env=env,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            deadline = time.monotonic() + 8
            try:
                while True:
                    observed = status()
                    assert pending.poll() is None, "long request finished before fault injection"
                    # Busy includes upload. The exchange thread starts after
                    # end_audio; require that and native CPU progress together.
                    if (observed["state"] == "busy" and observed["worker_pid"] == pid
                            and threads(server.pid) > idle_threads and cpu_seconds(pid) > old_cpu + .02):
                        print("ACTIVE_NATIVE_EXCHANGE", args.mode, flush=True)
                        return pending
                    assert time.monotonic() < deadline, "active native computation not observed"
                    time.sleep(.01)
            except BaseException:
                pending.kill()
                pending.communicate(timeout=5)
                raise

        initial = transcribe(speech)
        first = worker()
        assert_speech(initial)
        assert_speech(transcribe(speech))
        assert worker() == first, "warm worker not reused"
        silent = transcribe(silence)
        print("SILENCE", "PASS" if silent == b"" else "UNPROVEN_NONEMPTY", repr(silent), flush=True)
        client = active_request(first)
        busy = call("transcribe", speech)
        assert (busy.returncode, busy.stdout, busy.stderr) == (3, b"", b"busy\n"), busy
        client.send_signal(signal.SIGINT)
        out, err = client.communicate(timeout=8)
        assert (client.returncode, out, err) == (130, b"", b"interrupted\n"), (client.returncode, out, err)
        idle_and_reaped(first)
        assert_speech(transcribe(speech))
        second = worker()
        assert second != first
        client = active_request(second)
        assert int(ps(second, "ppid")) == server.pid, "only signal this test's child"
        os.kill(second, signal.SIGKILL)
        out, err = client.communicate(timeout=8)
        assert (client.returncode, out, err) == (1, b"", b"worker_failed\n"), (client.returncode, out, err)
        idle_and_reaped(second)
        assert_speech(transcribe(speech))
        assert worker() not in (first, second)
        print("LIFECYCLE PASS: warm PID, busy3, active cancel130/no delivery, crash1/no delivery, reap/recovery", flush=True)
    except SpeechMismatch as error:
        mismatch = error
    finally:
        if client is not None and client.poll() is None:
            client.kill()
            client.communicate(timeout=5)
        try:
            stopped = call("stop")
            out, err = server.communicate(timeout=8)
            assert (stopped.returncode, stopped.stderr) == (0, b""), stopped
            assert json.loads(stopped.stdout) == {
                "version": 1, "type": "stopped", "request_id": None, "code": None
            }, stopped
            assert (server.returncode, out, err) == (0, b"", b""), "server cleanup/output"
            assert all(not exists(pid) for pid in owned_workers), "stop left native child"
        finally:
            if server.poll() is None:
                for pid in owned_workers:
                    if exists(pid) and int(ps(pid, "ppid")) == server.pid:
                        os.kill(pid, signal.SIGKILL)
                server.kill()
                server.communicate(timeout=5)
        assert inputs == {path: digest(path) for path in inputs}, "caller WAV changed"
if mismatch is not None:
    # Emit only after stop/reap, WAV checks AND temporary-directory cleanup.
    # An exception in any cleanup path must remain an ordinary failing run.
    print("SUPPLIED_SPEECH_MISMATCH_CLEANUP_PASS:", mismatch, flush=True)
    raise SystemExit(42)
print("STOP/REAP AND INPUT PRESERVATION PASS", args.mode, flush=True)
