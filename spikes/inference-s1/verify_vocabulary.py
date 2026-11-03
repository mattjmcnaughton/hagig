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

        # These ONNX placeholders must NEVER reach native initialization. The
        # worker's missing audio is the positive control after tokenizer preflight.
        # The benchmark loads native before audio, so run only its rejecting cases.
        model = root / "model"
        model.mkdir()
        for name in ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx"]:
            (model / name).write_bytes(b"not a model; must not be loaded")
        bpe = "<unk>\t0\n▁\t-1\na\t-2\nb\t-3\né\t-4\nΩ\t-5\n▁ab\t-6\n"
        tokens = "<unk> 0\n▁ 1\na 2\nb 3\né 4\nΩ 5\n▁ab 6\n<blk> 7\n"
        messages = {
            "vocabulary_invalid": "Check vocabulary syntax and limits before retrying.",
            "model_invalid": "Verify or explicitly reinstall the candidate assets.",
            "audio_invalid": "Supply a supported readable WAV file.",
        }
        tokenizer_checks = 0

        def check_tokenizer(term, code, benchmark=True):
            nonlocal tokenizer_checks
            vocab.write_bytes(term.encode())
            commands = [[sys.executable, str(here / "worker_probe.py"), args.worker,
                         str(model), str(missing), str(vocab)]]
            if benchmark:
                commands.append([args.benchmark, str(model), str(missing), str(vocab)])
            for index, command in enumerate(commands):
                result = subprocess.run(command, capture_output=True, timeout=10)
                expected = (f'{code}: {messages[code]}\n' if index == 0
                            else f'Error: "{code}"\n')
                assert result.returncode == 1, "preflight must fail"
                assert result.stdout == b"", "no text or benchmark load record"
                assert result.stderr.decode() == expected, "only stable preflight error"
                tokenizer_checks += 1

        (model / "bpe.vocab").write_text(bpe)
        (model / "tokens.txt").write_text(tokens)
        for term in ["🤖", "ab🤖", "ab\n🤖", "e\u0301", "<unk>", "<blk>", "中"]:
            check_tokenizer(term, "vocabulary_invalid")
        for term in ["", "ab", "é", "Ω", "ab é", "ab\r\nΩ\r\n", "ab\nab", "▁"]:
            check_tokenizer(term, "audio_invalid", benchmark=False)
        for malformed_bpe, malformed_tokens in [
                (b"", tokens.encode()),
                (bpe.encode(), b""),
                (bpe.replace("a\t-2", "a\tNaN").encode(), tokens.encode()),
                (bpe.encode(), tokens.replace("<blk> 7", "<blk> 0").encode()),
                (b"<unk>\t0\n\xe2\x96\x81\t-1\nax\t-2\n",
                 "<unk> 0\n▁ 1\nax 2\n<blk> 3\n".encode()),
                (b" " * (131_073 - len(bpe.encode())) + bpe.encode(), tokens.encode()),
                (bpe.encode(), b" " * (131_073 - len(tokens.encode())) + tokens.encode()),
                (b"\xff", tokens.encode())]:
            (model / "bpe.vocab").write_bytes(malformed_bpe)
            (model / "tokens.txt").write_bytes(malformed_tokens)
            check_tokenizer("", "model_invalid")
            # Structural rejection still precedes all table/model inspection.
            check_tokenizer("a/b", "vocabulary_invalid")
    print(f"passed: 42 structural checks and {tokenizer_checks} tokenizer preflight checks")


if __name__ == "__main__":
    main()
