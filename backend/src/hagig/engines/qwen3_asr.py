"""Qwen3-ASR through Hugging Face transformers on PyTorch (TDD section 2).

Loads `AutoModelForMultimodalLM` and `AutoProcessor` from the installed
directory only: `local_files_only`, `use_safetensors=True`, never
`trust_remote_code`. The worker sets the offline variables before this module
is imported. Biasing uses the model's free-form context prompt
(`Vocabulary: a, b.`); with no vocabulary there is no prompt.

Device: CPU, in bfloat16. PyTorch's MPS backend has not been observed working
for this engine (hosted macOS VMs report no supported Metal GPU), so it is not
selected until a physical-Mac run shows it produces correct text.

Nothing here prints, logs or raises text that could carry a prompt, vocabulary
or transcript: failures are `EngineError` codes raised outside any `except`.
"""

import math
from collections.abc import Sequence
from pathlib import Path
from typing import TYPE_CHECKING, Any

from hagig.worker import EngineError

if TYPE_CHECKING:
    import numpy as np
    from numpy.typing import NDArray

SAMPLE_RATE = 16_000
DEVICE = "cpu"
# Generous for dictation (about 8 tokens per second of audio) while bounding a
# runaway decode on silence or noise.
_BASE_TOKENS = 32
_TOKENS_PER_SECOND = 8


def vocabulary_prompt(vocabulary: Sequence[str]) -> str | None:
    return f"Vocabulary: {', '.join(vocabulary)}." if vocabulary else None


class Engine:
    def __init__(self) -> None:
        self._processor: Any = None
        self._model: Any = None

    def load(self, model_dir: Path) -> None:
        # A missing engine stack is not a model problem: ImportError propagates
        # and the worker answers worker_failed.
        import torch
        from transformers import AutoModelForMultimodalLM, AutoProcessor
        from transformers.utils import logging as hf_logging

        hf_logging.set_verbosity_error()
        hf_logging.disable_progress_bar()
        loaded = None
        try:
            processor = AutoProcessor.from_pretrained(model_dir, local_files_only=True)
            model = AutoModelForMultimodalLM.from_pretrained(
                model_dir,
                local_files_only=True,
                use_safetensors=True,
                dtype=torch.bfloat16,
            )
            loaded = processor, model.to(DEVICE).eval()
        except MemoryError:
            raise
        except Exception:
            pass
        if loaded is None:
            raise EngineError("model_invalid")
        self._processor, self._model = loaded

    def transcribe(
        self, audio: "NDArray[np.float32]", vocabulary: Sequence[str]
    ) -> str:
        import torch

        processor, model = self._processor, self._model
        # The array, never a string: a string would be fetched as a URL or path.
        inputs = processor.apply_transcription_request(
            audio=audio, prompt=vocabulary_prompt(vocabulary), language="English"
        ).to(model.device, model.dtype)
        seconds = math.ceil(len(audio) / SAMPLE_RATE)
        with torch.inference_mode():
            output = model.generate(
                **inputs,
                max_new_tokens=_BASE_TOKENS + _TOKENS_PER_SECOND * seconds,
                do_sample=False,
            )
        generated = output[:, inputs["input_ids"].shape[1] :]
        text = processor.decode(generated, return_format="transcription_only")[0]
        return text.strip()
