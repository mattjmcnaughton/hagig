# S2: Python inference engines from trusted, maintained libraries

Owner-requested spike (2026-11-09). It compares three Python inference stacks on
the same synthetic WAV fixtures, with and without vocabulary biasing:

| Script | Library (maintainer) | Model (pinned revision) | Biasing |
| --- | --- | --- | --- |
| `qwen_asr.py` | `transformers` 5.22.2 + PyTorch 2.15.0 (Hugging Face; model code contributed upstream) | `Qwen/Qwen3-ASR-1.7B-hf` `bcd2b5b`, `Qwen/Qwen3-ASR-0.6B-hf` `7f1569a` | Documented free-form context prompt |
| `nemo_parakeet.py` | `nemo_toolkit[asr]` 3.0.0 + PyTorch 2.12.0 (NVIDIA) | `nvidia/parakeet-tdt-0.6b-v2` `ae9ad07` (same `.nemo` as S1's tokenizer source) | Per-stream GPU-PB phrase boosting, greedy label-looping TDT |
| `mlx_whisper_turbo.py` | `mlx-whisper` 0.4.3 + `mlx` 0.32.4 (Apple `ml-explore`) | `openai/whisper-large-v3-turbo` `41f01f3`, converted by Apple's `convert.py` at the 0.4.3 release commit `c1af8c4` | `initial_prompt` |

This is an investigation, not a Hagig worker, installer, privacy clearance or
adoption decision. Python in the product worker would need a constitution §7
amendment. Production code must not depend on this directory.

## Reproduce (Apple Silicon)

Requirements: macOS with `say`/`afconvert`, Python 3.11+ and uv 0.12.9 (uv is
the one tool this spike adds). Each engine is a PEP 723 script with its own
committed `*.py.lock`; `--locked` refuses drift. Linux resolves PyTorch from the
CPU wheel index; macOS uses PyPI's arm64 wheels.

```bash
cd spikes/inference-s2
W=../../.agentic/inference-s2   # ignored; models, fixtures and results stay out of Git
python3 fixtures.py $W/fixtures  # macOS say; Linux espeak-ng

# acquire = the explicit network step; run = offline transcription
uv run --locked --script qwen_asr.py acquire $W/models --variant 1.7b
uv run --locked --script qwen_asr.py run $W/models $W/fixtures $W/results/qwen-1.7b.jsonl --variant 1.7b
uv run --locked --script nemo_parakeet.py acquire $W/models
uv run --locked --script nemo_parakeet.py run $W/models $W/fixtures $W/results/nemo-parakeet.jsonl
uv run --locked --script mlx_whisper_turbo.py acquire $W/models
uv run --locked --script mlx_whisper_turbo.py run $W/models $W/fixtures $W/results/mlx-whisper-turbo.jsonl

python3 summarize.py $W/results/*.jsonl
```

`acquire` downloads only the pinned revision and checks pinned SHA-256s
(weights and Apple's converter script). `run` sets `HF_HUB_OFFLINE`,
`TRANSFORMERS_OFFLINE`, `HF_HUB_DISABLE_TELEMETRY` and `DO_NOT_TRACK` before
importing any model library and loads from local paths only.
`.github/workflows/inference-s2.yml` runs the same steps on a GitHub-hosted
`macos-15` runner per engine, uploading only JSONL/Markdown results.

## Method

`corpus.tsv` is S1's nine fixtures (four vocabulary-term clips, four spoken
controls including ordinary "amp", 3 s digital silence) plus two ~15 s
dictation-length prompts. The synthesizer column carries phonetic spellings;
references are written independently. `vocabulary.txt` equals S1's hotwords.

Per engine: cold load time, one unrecorded warmup, then every fixture in `plain`
and `biased` mode, three repeats each (median latency, determinism flag), and
process peak RSS. Language is fixed to English in both modes. `summarize.py`
reports term recovery, control and overall WER, false vocabulary insertions,
silence output and latency. Synthetic TTS is not human dictation; these are a
handful of clips, not accuracy samples, and the vocabulary is not held out.

## Hosted macOS results (run 42636236736, commit `f145a06`)

[Run](https://github.com/mattjmcnaughton/hagig/actions/runs/42636236736): GitHub
`macos-15` runners, "Apple M1 (Virtual)", 3 vCPU, 7 GiB, macOS 15.8.2. Fixtures
from `say`. Raw records and full transcripts are in [evidence/](evidence/);
`evidence/summary-run-42636236736.md` is `summarize.py` over them.

| Engine (device) | Terms plain → biased (of 9) | Control WER | Silence plain / biased | Median short / 13 s clip, biased | Peak RSS |
| --- | --- | --- | --- | --- | --- |
| Qwen3-ASR 1.7B (CPU) | 3 → **9** | 0 / 0 | "Okay." / "Vocabulary: Hagig, Ghostty, sherpa-onnx, Parakeet, Amp." | 11.7 s / 43.6 s | 4.2 GiB |
| Qwen3-ASR 0.6B (CPU) | 2 → **9** | 0 / 0 | "I'm." / "Hagig, Ghostty, sherpa-onnx, Parakeet, Amp." | 3.9 s / 16.0 s | 2.2 GiB |
| NeMo Parakeet TDT v2 (CPU, alpha 1.0) | 3 → 4 | 0 / 0 | **empty / empty** | 1.4 s / 3.4 s | 3.8 GiB |
| mlx-whisper turbo (Metal GPU) | 3 → 6 | 0 / 0 | "Thank you." / multilingual gibberish | 1.5 s / 2.0 s | 1.7 GiB |

Observations, all on synthetic speech and a nine-term vocabulary that was not
held out:

- **Qwen's context prompt is the strongest biasing**: every term fixed in both
  sizes, no control changes. Plain 1.7B once rendered Hagig as "Hugging Face".
  On silence both sizes **echo the prompt** when biased and invent a word plain.
- **NeMo GPU-PB at the documented starting alpha (1.0) barely moved**: only
  "Ghostty" in the long clip. Alpha is explicitly data-tuned and was not swept.
  It is the only engine that returned empty text on silence in both modes.
- **mlx-whisper's `initial_prompt`** fixed Ghostty and the long clip's terms but
  not short-clip "Hajig"/"Sherpa-Onix". Silence hallucinates in both modes; the
  biased silence text differed between runs while being stable within a run.
- **Latency is not representative of a real Mac.** torch 2.15 rejects the VM's
  "Apple Paravirtual device that does not support Metal 2.0", so Qwen ran on CPU.
  torch 2.12 accepted it, and NeMo on that MPS device produced garbage ("M", empty
  strings) then crashed in TDT label looping (`index 32 is out of bounds`; run
  42628772828), so the workflow pins NeMo to CPU. Only MLX ran on the GPU.
- Cold load: MLX 8.7 s, NeMo 47.7 s (unpacks the `.nemo` archive), Qwen ~1–2 s
  after the first-run environment install.

## Linux smoke (2026-11-09)

Linux orb smoke only, 2026-11-09 (2 vCPU x86-64, 3.8 GiB, no GPU). Fixtures were
the repository's existing flite `backend/tests/fixtures/speech.wav` ("Open the
project and run the tests") plus 3 s of digital silence, because no TTS tool is
installed in the orb. This checks the scripts, not Mac performance or accuracy.

- **Locks:** `uv lock --script` resolved 39 (Qwen), 150 (NeMo) and 43 (MLX)
  packages for both macOS arm64 and Linux.
- **Qwen3-ASR 0.6B, CPU bf16:** acquire and pinned SHA-256 passed. Load 1.2 s,
  ~3 s per clip, peak RSS 2.0 GiB. Speech → "Open for project and bronze test."
  in both modes. Silence → "I'm." plain, and **the vocabulary prompt itself**
  ("Hagig, Ghostty, sherpa-onnx, Parakeet, Amp.") when biased: prompt leakage on
  silence.
- **MLX Whisper turbo:** acquire, pinned SHA-256 and Apple's conversion passed
  (peak RSS 1.9 GiB, 21 s). MLX's Linux CPU backend is unusably slow for turbo
  (no result after 5 min; stopped). The same `transcribe` call path was then
  checked with a scratch `whisper-tiny.en` conversion: ~12 s per 2.4 s clip, so
  Linux MLX timings mean nothing. Mac/Metal is the only meaningful target.
- **NeMo Parakeet 0.6B v2:** acquire and pinned SHA-256 passed; `run` was
  OOM-killed on this 3.8 GiB orb after model load. The identical script against a
  scratch `nvidia/parakeet-tdt_ctc-110m` checkpoint ran on CPU (silence → empty
  text, ~0.22 s per clip). A scratch alpha sweep proved per-stream boosting reaches
  the decoder off CUDA: with phrases `run the tests`/`bronze`, alpha 0 gave "open
  to the project and brand tests" and alpha 1/3/6 "open to the project and bronze
  and test". The 110M checkpoint is a code-path check, not a result.
- `fixtures.py`'s macOS branch and every Mac/MPS/Metal path are unexercised here.

## Not established

Real Apple Silicon (non-VM) latency/memory, PyTorch MPS behavior, accuracy on real speech, tuned NeMo alpha,
runtime network/write observation, blocked-network operation, packaging, or any
privacy property. The NeMo lock includes `wandb`, `grpcio` and an OpenTelemetry
OTLP/HTTP exporter via `nv-one-logger`, and NeMo constructs a OneLogger callback
on every model init; whether anything is exported at runtime is unverified.
