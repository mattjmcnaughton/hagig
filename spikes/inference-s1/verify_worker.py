"""Opt-in SYNTHETIC evidence only; never persist captured native diagnostics.

Checks the actual executable/client boundary and same-supervisor recovery. All
raw positive-control diagnostics and syscall traces stay in memory, then die.
Only assertion outcomes, stable error codes, and numeric trace counts are printed.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import signal
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace

sys.dont_write_bytecode = True
from worker_probe import ERRORS, request

HERE = Path(__file__).resolve().parent
EXPECTED = "Run the unit tests before changing the parser."
NETWORK = re.compile(r"\b(?:socket|socketpair|connect|sendto|recvfrom|sendmsg|recvmsg|sendmmsg|recvmmsg|bind|listen|accept|accept4|getsockopt|setsockopt|getsockname|getpeername|shutdown)\(")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("worker")
    parser.add_argument("model")
    parser.add_argument("fixtures")
    args = parser.parse_args()
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    model = Path(args.model).resolve()
    fixtures = Path(args.fixtures).resolve()
    worker = str(Path(args.worker).resolve())
    wav = str(fixtures / "control-tests.wav")
    vocabulary = str(HERE / "hotwords.txt")
    inputs = list(model.iterdir()) + list(fixtures.glob("*.wav"))
    before = {p: hashlib.sha256(p.read_bytes()).digest() for p in inputs}

    def direct(model_path, vocab_path, mode):
        # Deliberate bypass ONLY to establish native leakage and a pre-crash result.
        read_fd, write_fd = os.pipe()
        try:
            result = subprocess.run(
                [worker, str(model_path), wav, str(vocab_path), str(write_fd), mode],
                pass_fds=(write_fd,), capture_output=True, timeout=30,
            )
            os.close(write_fd)
            write_fd = None
            reply = json.loads(os.read(read_fd, 65536))
            return result, reply
        finally:
            os.close(read_fd)
            if write_fd is not None:
                os.close(write_fd)

    def client(label, model_path=model, vocab_path=vocabulary, flags=(), error=None):
        command = [sys.executable, str(HERE / "worker_probe.py"), worker,
                   str(model_path), wav, str(vocab_path), *flags]
        # -s 0 omits write payloads; all trace strings (including paths) are
        # captured only in memory. Native stdout/stderr remain /dev/null.
        with os.fdopen(os.memfd_create("synthetic-trace", os.MFD_CLOEXEC), "w+b") as capture:
            result = subprocess.run(
                ["strace", "-f", "-qq", "-s", "0", "-yy", "-o",
                 f"/proc/self/fd/{capture.fileno()}", "-e",
                 "trace=%network,%file,write,writev,pwrite64,process", *command],
                pass_fds=(capture.fileno(),), capture_output=True, timeout=40,
            )
            capture.seek(0)
            trace = capture.read().decode().splitlines()
        stderr = result.stderr.decode().rstrip("\n")
        assert trace, "tracing must actually be enabled"
        assert not any(NETWORK.search(line) for line in trace)
        writable = [line for line in trace if re.search(r"\b(?:open|openat|creat)\(", line)
                    and re.search(r"O_WRONLY|O_RDWR|O_CREAT|O_TRUNC|creat\(", line)]
        assert writable and all('"/dev/null"' in line for line in writable)
        assert not any(secret in result.stdout or secret in stderr.encode() for secret in
                       [path_canary.encode(), vocabulary_canary.encode(), b"SYNTHETIC_STDOUT_DIAGNOSTIC"])
        if error:
            assert result.returncode == (130 if error == "cancelled" else 1)
            assert result.stdout == b""
            assert stderr == f"{error}: {ERRORS[error]}"
        else:
            assert result.returncode == 0
            assert result.stdout.decode() == EXPECTED + "\n"
            assert stderr == ""
        native_stderr = sum("write(2</dev/null" in line for line in trace)
        discarded_stdout = sum("write(1</dev/null" in line for line in trace)
        private_replies = sum(bool(re.search(r"\bwrite\(([3-9]|\d{2,})<pipe:", line)) for line in trace)
        if label in ["corrupt-canary", "native-vocabulary-warning", "crash-after-real-result"]:
            assert native_stderr > 0, "native diagnostics must really reach the discard sink"
        if label == "crash-after-real-result":
            assert discarded_stdout > 0
        if label in ["crash-after-real-result", "cancel-buffered-real-result", "timeout-buffered-real-result"]:
            assert private_replies > 0, "the real reply must precede failure/cancellation/deadline"
        print(json.dumps({"case": label, "client_exit": result.returncode,
                          "error": error, "stdout_empty": result.stdout == b"",
                          "network_syscalls": 0, "writable_opens_except_dev_null": 0,
                          "discarded_stderr_writes": native_stderr,
                          "discarded_stdout_writes": discarded_stdout,
                          "private_reply_written": private_replies > 0}))

    with tempfile.TemporaryDirectory(prefix="worker-synthetic-") as temp:
        root = Path(temp)
        path_canary = "SYNTHETIC_PRIVATE_PATH_CANARY"
        vocabulary_canary = "SYNTHETIC_PRIVATE_VOCABULARY_CANARY :1 trailing"
        corrupt = root / path_canary
        corrupt.mkdir()
        for file in model.iterdir():
            if file.name != "encoder.int8.onnx":
                (corrupt / file.name).symlink_to(file)
        (corrupt / "encoder.int8.onnx").write_bytes(b"not an ONNX model\n")
        bad_vocab = root / "synthetic-vocabulary.txt"
        bad_vocab.write_text(vocabulary_canary + "\n")

        raw, reply = direct(corrupt, vocabulary, "normal")
        assert path_canary.encode() in raw.stderr
        assert reply == {"error": "model_invalid"} and raw.returncode == 1
        del raw, reply
        raw, reply = direct(model, bad_vocab, "crash-after-result")
        assert vocabulary_canary.encode() in raw.stderr
        assert b"Encode hotwords failed" in raw.stderr
        assert raw.stdout == b"SYNTHETIC_STDOUT_DIAGNOSTIC\n"
        assert raw.returncode == -signal.SIGABRT
        assert reply == {"text": EXPECTED}
        del raw, reply
        print(json.dumps({"native_positive_controls": "passed",
                          "path_and_vocabulary_actually_emitted": True,
                          "real_reply_preceded_sigabrt": True,
                          "raw_diagnostics_persisted": False}))

        client("missing", root / "absent", error="model_missing")
        client("corrupt-canary", corrupt, error="model_invalid")
        client("native-vocabulary-warning", vocab_path=bad_vocab)
        client("crash-after-real-result", vocab_path=bad_vocab,
               flags=("--mode", "crash-after-result"), error="worker_failed")
        client("cancel-buffered-real-result", flags=("--mode", "hold-after-result", "--cancel-after-result"),
               error="cancelled")
        client("timeout-buffered-real-result", flags=("--mode", "hold-after-result", "--timeout", "8"),
               error="deadline_exceeded")
        client("fresh-worker-recovery")

        # Real client SIGINT, in addition to the deterministic buffered-reply seam.
        with subprocess.Popen(
            [sys.executable, str(HERE / "worker_probe.py"), worker, str(model), wav,
             vocabulary, "--mode", "hold-after-result"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        ) as interrupted:
            try:
                deadline = time.monotonic() + 5
                children = []
                while not children and time.monotonic() < deadline:
                    children = Path(f"/proc/{interrupted.pid}/task/{interrupted.pid}/children").read_text().split()
                    time.sleep(0.01)
                assert len(children) == 1
                interrupted.send_signal(signal.SIGINT)
                out, err = interrupted.communicate(timeout=5)
                assert interrupted.returncode == 130 and out == b""
                assert err.decode() == f"cancelled: {ERRORS['cancelled']}\n"
                assert not Path(f"/proc/{children[0]}").exists()
            finally:
                if interrupted.poll() is None:
                    interrupted.kill()
                    interrupted.wait()
        print(json.dumps({"sigint_during_request": "passed", "child_reaped": True,
                          "client_stdout_empty": True, "client_exit": 130}))

        # Same Python supervisor process survives each request, not just a new CLI.
        for model_path, mode, cancel, expected_error in [
            (corrupt, "normal", False, "model_invalid"),
            (model, "crash-after-result", False, "worker_failed"),
            (model, "hold-after-result", True, "cancelled"),
            (model, "normal", False, None),
        ]:
            text, error = request(SimpleNamespace(worker=worker, model=str(model_path), wav=wav,
                                                 vocabulary=vocabulary, mode=mode,
                                                 cancel_after_result=cancel, timeout=30))
            assert error == expected_error
            assert text == (EXPECTED if error is None else None)
            try:
                os.waitpid(-1, os.WNOHANG)
            except ChildProcessError:
                pass
            else:
                raise AssertionError("worker must be reaped before the next request")
        print(json.dumps({"same_supervisor_failure_cancel_recovery": "passed",
                          "unreaped_children": 0,
                          "native_libraries_in_supervisor": "libsherpa-onnx" in Path("/proc/self/maps").read_text()}))
        assert "libsherpa-onnx" not in Path("/proc/self/maps").read_text()

    assert all(hashlib.sha256(p.read_bytes()).digest() == digest for p, digest in before.items())
    assert resource.getrlimit(resource.RLIMIT_CORE) == (0, 0)
    print(json.dumps({"input_hashes_unchanged": len(before), "core_limit": [0, 0], "verification": "passed"}))


if __name__ == "__main__":
    main()
