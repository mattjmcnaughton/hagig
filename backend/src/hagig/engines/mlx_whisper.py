"""Whisper large-v3-turbo through Apple's mlx-whisper on MLX (TDD section 2).

Loads the directory `hagig model install` converted (`config.json`,
`weights.safetensors`) with mlx-whisper's `load_model`, in float16, on MLX's
default device (Metal on Apple Silicon). Biasing uses Whisper's
`initial_prompt` (`Vocabulary: a, b.`); with no vocabulary there is no prompt.
mlx-whisper keeps only the prompt's last 223 tokens (half the 448-token text
context), so a long vocabulary loses its first terms; nothing fails.

Download fallbacks, closed here rather than trusted to the offline variables:

- `load_model` calls `huggingface_hub.snapshot_download` when its path does
  not exist. `load` checks the directory itself and replaces the name in
  `mlx_whisper.load_models` with a function that refuses, so a later lookup
  cannot reach the Hub (or a stale Hub cache) either.
- `transcribe` resolves its model through `ModelHolder` by path. `load` puts
  the loaded model there under the same path, so `transcribe` never loads.
- The tokenizer reads mlx-whisper's bundled `assets/*.tiktoken` into
  `tiktoken.Encoding` directly; tiktoken's downloading `get_encoding` and its
  cache are never called.

Nothing here prints (`verbose=None` disables the progress bar and segment
output), logs or raises text that could carry a prompt, vocabulary or
transcript: a load failure is `ModelError("model_invalid")` raised outside
any `except`.
"""

from collections.abc import Sequence
from pathlib import Path
from typing import TYPE_CHECKING, NoReturn

from hagig.engines import vocabulary_prompt
from hagig.models import ModelError

if TYPE_CHECKING:
    import numpy as np
    from numpy.typing import NDArray


def _refuse_download(*_args: object, **_kwargs: object) -> NoReturn:
    raise ModelError("model_invalid")


class Engine:
    def __init__(self) -> None:
        self._path = ""

    def load(self, model_dir: Path) -> None:
        import mlx.core as mx
        from mlx_whisper import load_models
        from mlx_whisper.transcribe import ModelHolder

        load_models.snapshot_download = _refuse_download
        path = str(model_dir)
        model = None
        if model_dir.is_dir():
            try:
                model = load_models.load_model(path, dtype=mx.float16)
            except MemoryError:
                raise
            except Exception:
                pass
        if model is None:
            raise ModelError("model_invalid")
        ModelHolder.model, ModelHolder.model_path = model, path
        self._path = path

    def transcribe(
        self, audio: "NDArray[np.float32]", vocabulary: Sequence[str]
    ) -> str:
        import mlx_whisper

        result = mlx_whisper.transcribe(
            audio,
            path_or_hf_repo=self._path,
            language="en",
            initial_prompt=vocabulary_prompt(vocabulary),
            verbose=None,
        )
        return str(result["text"]).strip()
