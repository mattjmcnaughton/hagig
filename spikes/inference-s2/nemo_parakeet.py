# /// script
# requires-python = ">=3.11,<3.13"
# dependencies = [
#   "nemo_toolkit[asr]==3.0.0",
#   "torch==2.12.0",
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
"""Parakeet TDT 0.6B v2 through NVIDIA NeMo (PyTorch).

  uv run --script nemo_parakeet.py acquire MODELS
  uv run --script nemo_parakeet.py run MODELS FIXTURES OUT.jsonl [--device auto|cpu|mps]

Biasing uses NeMo's per-stream GPU-PB phrase boosting with greedy label-looping
TDT decoding (the pure-torch path off CUDA; Triton is CUDA-only).
"""

import argparse
import os

import common

REPO = "nvidia/parakeet-tdt-0.6b-v2"
REVISION = "ae9ad07059c7c739ffaf932226a8fe64ae2620b0"
FILE = "parakeet-tdt-0.6b-v2.nemo"
SHA256 = "d99e39955c9d3d0350d8fb7c75e40c64a2b2eaeb003883d7c941fd2e8747b28c"

parser = argparse.ArgumentParser()
parser.add_argument("action", choices=["acquire", "run"])
parser.add_argument("models")
parser.add_argument("fixtures", nargs="?")
parser.add_argument("out", nargs="?")
parser.add_argument("--device", choices=["auto", "cpu", "mps"], default="auto")
parser.add_argument("--alpha", type=float, default=1.0, help="boosting_model_alpha")
parser.add_argument("--repeats", type=int, default=3)
args = parser.parse_args()
local = f"{args.models}/{FILE}"

if args.action == "acquire":
    from huggingface_hub import hf_hub_download

    hf_hub_download(REPO, FILE, revision=REVISION, local_dir=args.models)
    common.verify(local, SHA256)
    raise SystemExit(0)

common.go_offline()
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")  # NVIDIA's documented MPS setting
import torch  # noqa: E402
import nemo  # noqa: E402
import nemo.collections.asr as nemo_asr  # noqa: E402
from nemo.collections.asr.parts.context_biasing.biasing_multi_model import BiasingRequestItemConfig  # noqa: E402
from nemo.collections.asr.parts.context_biasing.boosting_graph_batched import BoostingTreeModelConfig  # noqa: E402
from nemo.collections.asr.parts.utils.rnnt_utils import Hypothesis  # noqa: E402
from omegaconf import open_dict  # noqa: E402

device = args.device
if device == "auto":
    device = "mps" if torch.backends.mps.is_available() else "cpu"
state = {}


def load():
    model = nemo_asr.models.ASRModel.restore_from(local, map_location=torch.device(device))
    with open_dict(model.cfg.decoding):
        model.cfg.decoding.strategy = "greedy_batch"
        model.cfg.decoding.greedy.loop_labels = True
        model.cfg.decoding.greedy.enable_per_stream_biasing = True
    model.change_decoding_strategy(model.cfg.decoding, verbose=False)
    state["model"] = model.eval()


def transcribe(audio, vocab):
    partial = None
    if vocab:
        request = BiasingRequestItemConfig(
            boosting_model_cfg=BoostingTreeModelConfig(key_phrases_list=list(vocab)),
            boosting_model_alpha=args.alpha,
            cache_key="vocabulary",
        )
        partial = [Hypothesis.empty_with_biasing_cfg(biasing_cfg=request)]
    with torch.inference_mode():
        result = state["model"].transcribe(
            audio=[audio], batch_size=1, partial_hypothesis=partial, return_hypotheses=True, verbose=False
        )
    return result[0].text.strip()


common.run_suite(
    "nemo-parakeet-tdt-0.6b-v2", f"{REPO}@{REVISION}", load, transcribe, args.fixtures, args.out, args.repeats,
    lambda: {"device": device, "torch": torch.__version__, "nemo": nemo.__version__, "boosting_alpha": args.alpha},
)
