"""Synthetic CLI contract regression checks, no speech fixtures or native decoding.

Requires already built benchmark/worker. Deliberately missing model/audio paths
make validation ordering observable. No private vocabulary or recordings allowed.
"""
import argparse
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("worker")
    parser.add_argument("benchmark")
    args = parser.parse_args()
    here = Path(__file__).resolve().parent
    cases = [b"\n", b"Hagig\n\n", b" Hagig", b"Hagig ", b"hello  world",
             b"hello\tworld", b"hello\rworld", b"Hagig\0", b"a/b", b"a :1 trailing",
             b"a:1", b"\xff", b"a" * 129, "é".encode() * 65,
             b"\n".join([b"a"] * 257), "a\u00a0b".encode()]
    with tempfile.TemporaryDirectory(prefix="s1-vocabulary-contract-") as temp:
        root = Path(temp)
        vocab = root / "vocabulary.txt"
        missing = root / "absent"

        def check(data, code):
            vocab.write_bytes(data)
            commands = [
                [sys.executable, str(here / "worker_probe.py"), args.worker,
                 str(missing), str(missing), str(vocab)],
                [args.benchmark, str(missing), str(missing), str(vocab)],
            ]
            for index, command in enumerate(commands):
                result = subprocess.run(command, capture_output=True, timeout=10)
                expected = (f'{code}: Check vocabulary syntax and limits before retrying.\n'
                            if index == 0 and code == "vocabulary_invalid" else
                            'model_missing: Install the candidate assets explicitly before retrying.\n'
                            if index == 0 else f'Error: "{code}"\n')
                assert result.returncode == 1, "request must fail"
                assert result.stdout == b"", "no transcript or benchmark load record"
                assert result.stderr.decode() == expected, "only stable content-free error"

        for data in cases:
            check(data, "vocabulary_invalid")
        for data in [b"", b"Hagig\nsherpa-onnx\nhello world\n", b"Hagig\r\nGhostty\r\n",
                     b"a" * 128, b"\n".join([b"a"] * 256)]:
            check(data, "model_missing")
    print(f"passed: {len(cases)} invalid and 5 valid vocabularies across both entry points")


if __name__ == "__main__":
    main()
