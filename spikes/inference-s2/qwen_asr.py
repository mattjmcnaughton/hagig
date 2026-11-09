# /// script
# requires-python = ">=3.11,<3.13"
# dependencies = [
#   "transformers==5.22.2",
#   "torch==2.15.0",
#   "numpy",
#   "huggingface_hub",
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
"""Qwen3-ASR through Hugging Face transformers (PyTorch).

  uv run --script qwen_asr.py acquire MODELS [--variant 1.7b|0.6b]
  uv run --script qwen_asr.py run MODELS FIXTURES OUT.jsonl [--variant ...] [--device auto|cpu|mps]

Biasing uses the model's documented free-form context prompt.
"""

import argparse

import common

PINS = {
    "1.7b": ("Qwen/Qwen3-ASR-1.7B-hf", "bcd2b5b7f32b480ab5790554cfa8347f246a14f3",
             "2db53c7d81bd9b8cbc6a074e89be2c968a0d373fb4ee68bb1b1e14f7042dfee1"),
    "0.6b": ("Qwen/Qwen3-ASR-0.6B-hf", "7f1569a48a89f3e3f4dc3a5c9d28bddd903bc76c",
             "d3f212dd20abecd315d830bc54ae3865e56ebfc3276484e57b771288ba27fd35"),
}

parser = argparse.ArgumentParser()
parser.add_argument("action", choices=["acquire", "run"])
parser.add_argument("models")
parser.add_argument("fixtures", nargs="?")
parser.add_argument("out", nargs="?")
parser.add_argument("--variant", choices=PINS, default="1.7b")
parser.add_argument("--device", choices=["auto", "cpu", "mps"], default="auto")
parser.add_argument("--repeats", type=int, default=3)
args = parser.parse_args()
repo, revision, weights_sha = PINS[args.variant]
local = f"{args.models}/qwen3-asr-{args.variant}-hf"

if args.action == "acquire":
    from huggingface_hub import snapshot_download

    snapshot_download(repo, revision=revision, local_dir=local)
    common.verify(f"{local}/model.safetensors", weights_sha)
    raise SystemExit(0)

common.go_offline()
import torch  # noqa: E402
import transformers  # noqa: E402
from transformers import AutoModelForMultimodalLM, AutoProcessor  # noqa: E402

device = args.device
if device == "auto":
    device = "mps" if torch.backends.mps.is_available() else "cpu"
state = {}


def load():
    state["processor"] = AutoProcessor.from_pretrained(local)
    state["model"] = AutoModelForMultimodalLM.from_pretrained(local, dtype=torch.bfloat16).to(device).eval()


def transcribe(audio, vocab):
    processor, model = state["processor"], state["model"]
    prompt = f"Vocabulary: {', '.join(vocab)}." if vocab else None
    inputs = processor.apply_transcription_request(audio=audio, prompt=prompt, language="English")
    inputs = inputs.to(model.device, model.dtype)
    with torch.inference_mode():
        output = model.generate(**inputs, max_new_tokens=256, do_sample=False)
    generated = output[:, inputs["input_ids"].shape[1]:]
    return processor.decode(generated, return_format="transcription_only")[0].strip()


common.run_suite(
    f"qwen3-asr-{args.variant}", f"{repo}@{revision}", load, transcribe, args.fixtures, args.out, args.repeats,
    lambda: {"device": device, "dtype": "bfloat16", "torch": torch.__version__, "transformers": transformers.__version__},
)
