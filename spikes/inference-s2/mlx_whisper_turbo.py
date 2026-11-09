# /// script
# requires-python = ">=3.11,<3.13"
# dependencies = [
#   "mlx-whisper==0.4.3",
#   "mlx==0.32.4",
#   "mlx[cpu]==0.32.4; sys_platform == 'linux'",
#   "torch==2.15.0",
#   "numpy",
#   "huggingface_hub",
#   "tqdm",
# ]
#
# [tool.uv.sources]
# torch = { index = "pytorch-cpu", marker = "sys_platform == 'linux'" }
#
# [[tool.uv.index]]
# name = "pytorch-cpu"
# url = "https://download.pytorch.org/whl/cpu"
# explicit = true
# ///
"""Whisper large-v3-turbo through Apple's mlx-whisper (MLX, Metal on Apple Silicon).

  uv run --script mlx_whisper_turbo.py acquire MODELS
  uv run --script mlx_whisper_turbo.py run MODELS FIXTURES OUT.jsonl

Weights: OpenAI's own Hugging Face safetensors, converted with Apple's convert.py
from the mlx-examples commit that released mlx-whisper 0.4.3. Not mlx-community.
Biasing uses Whisper's `initial_prompt`. Linux runs MLX's CPU backend (smoke only).
"""

import argparse
import pathlib
import subprocess
import sys
import urllib.request

import common

REPO = "openai/whisper-large-v3-turbo"
REVISION = "41f01f3fe87f28c78e2fbf8b568835947dd65ed9"
WEIGHTS_SHA256 = "542566a422ae4f3fd23f1ba11add198fca01bbf82e66e6a2857b3f608b1eb9d1"
CONVERT_COMMIT = "c1af8c46bd4c4704cff1561736a634cee38efc6c"  # "version (#1387)" = mlx-whisper 0.4.3
CONVERT_SHA256 = "9d5a03b60843e89512d1f825a6a6ee662fa2d17af347220c5e6a8b69af7574aa"

parser = argparse.ArgumentParser()
parser.add_argument("action", choices=["acquire", "run"])
parser.add_argument("models")
parser.add_argument("fixtures", nargs="?")
parser.add_argument("out", nargs="?")
parser.add_argument("--repeats", type=int, default=3)
args = parser.parse_args()
models = pathlib.Path(args.models)
source, converted = models / "whisper-large-v3-turbo-hf", models / "whisper-large-v3-turbo-mlx"

if args.action == "acquire":
    from huggingface_hub import snapshot_download

    snapshot_download(REPO, revision=REVISION, local_dir=source, allow_patterns=["*.json", "model.safetensors", "*.txt"])
    common.verify(source / "model.safetensors", WEIGHTS_SHA256)
    script = models / "mlx-whisper-convert.py"
    url = f"https://raw.githubusercontent.com/ml-explore/mlx-examples/{CONVERT_COMMIT}/whisper/convert.py"
    urllib.request.urlretrieve(url, script)
    common.verify(script, CONVERT_SHA256)
    subprocess.run(
        [sys.executable, str(script), "--torch-name-or-path", str(source), "--mlx-path", str(converted), "--dtype", "float16"],
        check=True,
    )
    raise SystemExit(0)

common.go_offline()
import mlx.core as mx  # noqa: E402
import mlx_whisper  # noqa: E402
from mlx_whisper.transcribe import ModelHolder  # noqa: E402

model_path = str(converted)


def load():
    ModelHolder.get_model(model_path, mx.float16)


def transcribe(audio, vocab):
    prompt = f"Vocabulary: {', '.join(vocab)}." if vocab else None
    result = mlx_whisper.transcribe(audio, path_or_hf_repo=model_path, language="en", initial_prompt=prompt, verbose=None)
    return result["text"].strip()


common.run_suite(
    "mlx-whisper-large-v3-turbo", f"{REPO}@{REVISION}", load, transcribe, args.fixtures, args.out, args.repeats,
    lambda: {"device": str(mx.default_device()), "mlx": mx.__version__, "mlx_whisper": "0.4.3", "dtype": "float16"},
)
