"""Experimental Linux one-shot supervisor; no native library in this process.

Only accepted text goes to client stdout. Diagnostics are discarded at spawn,
not captured and redacted later. This is not Hagig's server/protocol/security API.
"""
import argparse
import json
import os
import resource
import selectors
import signal
import subprocess
import sys
import time

ERRORS = {
    "model_missing": "Install the candidate assets explicitly before retrying.",
    "model_invalid": "Verify or explicitly reinstall the candidate assets.",
    "vocabulary_unreadable": "Check vocabulary file permissions and retry.",
    "audio_invalid": "Supply a supported readable WAV file.",
    "worker_failed": "Inference worker failed; retry as a new request.",
    "cancelled": "Request cancelled; no result delivered.",
    "deadline_exceeded": "Inference exceeded the experiment deadline; retry as a new request.",
}


def request(args):
    # Disable core files for this supervisor and its descendants before native load.
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    read_fd, write_fd = os.pipe()
    child = None
    data = bytearray()
    try:
        child = subprocess.Popen(
            [args.worker, args.model, args.wav, args.vocabulary, str(write_fd), args.mode],
            stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            pass_fds=(write_fd,),
        )
        os.close(write_fd)
        write_fd = None
        os.set_blocking(read_fd, False)
        deadline = time.monotonic() + args.timeout
        with selectors.DefaultSelector() as selector:
            selector.register(read_fd, selectors.EVENT_READ)
            while True:
                if time.monotonic() >= deadline:
                    return None, "deadline_exceeded"
                if selector.select(timeout=0.02):
                    chunk = os.read(read_fd, 65537)
                    data.extend(chunk)
                    if len(data) > 65536:
                        return None, "worker_failed"
                    if args.cancel_after_result and b"\n" in data:
                        return None, "cancelled"
                    if not chunk:
                        # A closed reply pipe does not certify successful exit.
                        break
            status = child.wait(timeout=max(0.001, deadline - time.monotonic()))
        try:
            record = json.loads(data)
        except (ValueError, UnicodeError):
            return None, "worker_failed"
        if status != 0:
            code = record.get("error") if isinstance(record, dict) else None
            return None, code if status == 1 and code in ERRORS else "worker_failed"
        if not isinstance(record, dict) or set(record) != {"text"} or not isinstance(record["text"], str):
            return None, "worker_failed"
        return record["text"], None
    except KeyboardInterrupt:
        return None, "cancelled"
    except subprocess.TimeoutExpired:
        return None, "deadline_exceeded"
    except (OSError, ValueError):
        return None, "worker_failed"
    finally:
        if child is not None:
            if child.poll() is None:
                child.kill()
            child.wait()
            child.stdin.close()
        os.close(read_fd)
        if write_fd is not None:
            os.close(write_fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("worker")
    parser.add_argument("model")
    parser.add_argument("wav")
    parser.add_argument("vocabulary")
    parser.add_argument("--timeout", type=float, default=30)
    parser.add_argument("--mode", choices=["normal", "crash-after-result", "hold-after-result"], default="normal")
    parser.add_argument("--cancel-after-result", action="store_true", help="synthetic fault seam; discard an already buffered real reply")
    args = parser.parse_args()
    # The orb's noninteractive launcher can inherit SIG_IGN; make CLI Ctrl-C real.
    signal.signal(signal.SIGINT, signal.default_int_handler)
    text, error = request(args)
    if error:
        print(f"{error}: {ERRORS[error]}", file=sys.stderr)
        return 130 if error == "cancelled" else 1
    if text:
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
