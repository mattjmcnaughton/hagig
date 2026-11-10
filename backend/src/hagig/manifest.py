"""Tracked model manifests (TDD sections 2 and 4).

One JSON file per model alias in `hagig/manifests/` pins the publisher's
repository and revision and lists every file to download with its size and
SHA-256. Whisper also pins Apple's `convert.py` and the files it produces;
their hashes are recorded at install, because only the installer creates them.

Parsing is strict: unknown keys and unsafe names are `manifest_invalid`, any
pickle format is `manifest_pickle`, and a manifest with no safetensors among
its downloads or installed files is `manifest_no_safetensors`. A manifest's
identity is the SHA-256 of its file bytes (`Manifest.digest`), which every
installation records.
"""

import contextlib
import hashlib
from functools import cache
from importlib import resources
from typing import Annotated, Literal, Self, get_args

from pydantic import (
    BaseModel,
    ConfigDict,
    Field,
    PrivateAttr,
    StringConstraints,
    ValidationError,
    model_validator,
)
from pydantic_core import PydanticCustomError

from hagig.config import ModelId
from hagig.models import NAME_PATTERN, RECORD_NAME, SHA256_PATTERN

# Formats that unpickle (execute code) on load. Never downloaded or loaded.
PICKLE_SUFFIXES = (".bin", ".pt", ".pth", ".pkl", ".pickle", ".ckpt")

ManifestCode = Literal["manifest_pickle", "manifest_no_safetensors", "manifest_invalid"]
_CODES = get_args(ManifestCode)
Sha256 = Annotated[str, StringConstraints(pattern=SHA256_PATTERN)]
Commit = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{40}$")]
# Installed files sit directly in the installation directory: one plain name.
FileName = Annotated[str, StringConstraints(pattern=NAME_PATTERN)]
Repository = Annotated[
    str, StringConstraints(pattern=r"^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9._-]+$")
]
HttpUrl = Annotated[str, StringConstraints(pattern=r"^https?://[^\s]+$")]
Engine = Literal["qwen3-asr", "mlx-whisper"]


class ManifestError(Exception):
    """A manifest is unknown or malformed. `code` is stable and content-free."""

    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


class _Strict(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True, strict=True)


class File(_Strict):
    path: FileName
    size: int = Field(gt=0)
    sha256: Sha256


class Source(_Strict):
    publisher: str
    repository: Repository
    revision: Commit
    license: str
    license_url: HttpUrl
    # Each file is downloaded from `download + path`.
    download: HttpUrl


class Conversion(_Strict):
    """A pinned converter run on the downloaded files (MLX Whisper only)."""

    publisher: str
    repository: Repository
    commit: Commit
    path: str
    license: str
    license_url: HttpUrl
    url: HttpUrl
    size: int = Field(gt=0)
    sha256: Sha256
    arguments: tuple[str, ...]
    outputs: tuple[FileName, ...] = Field(min_length=1)


class Manifest(_Strict):
    format: Literal[1]
    id: ModelId
    engine: Engine
    apple_silicon_only: bool
    source: Source
    files: tuple[File, ...] = Field(min_length=1)
    conversion: Conversion | None
    # SHA-256 of the manifest file's bytes, set only by `parse_manifest`.
    _digest: str = PrivateAttr(default="")

    @property
    def digest(self) -> str:
        return self._digest

    @model_validator(mode="after")
    def _safe(self) -> Self:
        for names in ([f.path for f in self.files], self.installed_files):
            if len(set(names)) != len(names) or RECORD_NAME in names:
                raise _error("manifest_invalid")
            if any(name.endswith(PICKLE_SUFFIXES) for name in names):
                raise _error("manifest_pickle")
            if not any(name.endswith(".safetensors") for name in names):
                raise _error("manifest_no_safetensors")
        if not self.source.download.endswith("/"):
            raise _error("manifest_invalid")
        return self

    @property
    def installed_files(self) -> tuple[str, ...]:
        """Names in a published installation, besides the install record."""
        if self.conversion is not None:
            return self.conversion.outputs
        return tuple(f.path for f in self.files)


def _error(code: ManifestCode) -> PydanticCustomError:
    return PydanticCustomError(code, code)


def parse_manifest(data: bytes) -> Manifest:
    """Parse and validate manifest bytes; the digest is their SHA-256."""
    failure = "manifest_invalid"
    manifest = None
    try:
        manifest = Manifest.model_validate_json(data)
    except ValidationError as error:
        failure = next(
            (e["type"] for e in error.errors() if e["type"] in _CODES), failure
        )
    if manifest is None:
        raise ManifestError(failure)
    manifest._digest = hashlib.sha256(data).hexdigest()
    return manifest


@cache
def load_manifest(model_id: str) -> Manifest:
    """The tracked manifest for a configured model alias."""
    if model_id not in get_args(ModelId):
        raise ManifestError("unknown_model")
    data = None
    with contextlib.suppress(OSError):
        data = (
            resources.files("hagig") / "manifests" / f"{model_id}.json"
        ).read_bytes()
    if data is None:
        # The package data is missing from this environment.
        raise ManifestError("manifest_unavailable")
    manifest = parse_manifest(data)
    if manifest.id != model_id:
        raise ManifestError("manifest_invalid")
    return manifest
