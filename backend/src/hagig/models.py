"""Installed models (TDD sections 2-4).

A minimal stand-in until #47's manifests and installer: each configured alias
names its engine, and a model counts as installed when its directory exists.
The worker's `load` validates the files themselves. #47 replaces this check
with manifest validation behind the same function.
"""

from pathlib import Path

from hagig.config import ModelId

ENGINE_BY_MODEL: dict[ModelId, str] = {
    "qwen3-asr-0.6b": "qwen3-asr",
    "qwen3-asr-1.7b": "qwen3-asr",
    "whisper-large-v3-turbo": "mlx-whisper",
}


def installed_model_dir(models_root: Path, model_id: ModelId) -> Path | None:
    """The model's installation directory, or None if it is not installed."""
    path = models_root / model_id
    return path if path.is_dir() else None
