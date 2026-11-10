"""Tracked model manifests (TDD sections 2 and 4).

One JSON file per model alias in `hagig/manifests/` pins the publisher's
repository and revision and lists every file to download with its size and
SHA-256. Whisper also pins Apple's `convert.py` and the files it produces;
their hashes are recorded at install, because only the installer creates them.

Parsing is strict: unknown keys, unsafe names and pickle formats are refused,
and weights must be safetensors. A manifest's identity is the SHA-256 of its
file bytes (`Manifest.digest`), which every installation records.
"""

import hashlib
import json
from functools import cache
from importlib import resources
from typing import Annotated, Literal, Self, get_args

from pydantic import (
    BaseModel,
    ConfigDict,
    Field,
    StringConstraints,
    ValidationError,
    model_validator,
)

from hagig.config import ModelId
from hagig.models import RECORD_NAME

# Formats that unpickle (execute code) on load. Never downloaded or loaded.
PICKLE_SUFFIXES = (".bin", ".pt", ".pth", ".pkl", ".pickle", ".ckpt")

Sha256 = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{64}$")]
Commit = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{40}$")]
# Installed files sit directly in the installation directory: one plain name.
FileName = Annotated[
    str, StringConstraints(pattern=r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
]
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
    # SHA-256 of the manifest file; set by `parse_manifest`, not by the file.
    digest: str = Field(default="", exclude=True)

    @model_validator(mode="after")
    def _safe(self) -> Self:
        downloaded = [f.path for f in self.files]
        installed = (
            list(self.conversion.outputs) if self.conversion else list(downloaded)
        )
        for names in (downloaded, installed):
            if len(set(names)) != len(names) or RECORD_NAME in names:
                raise ValueError("manifest_invalid")
            if any(name.endswith(PICKLE_SUFFIXES) for name in names):
                raise ValueError("manifest_pickle")
            if not any(name.endswith(".safetensors") for name in names):
                raise ValueError("manifest_pickle")
        if not self.source.download.endswith("/"):
            raise ValueError("manifest_invalid")
        return self

    @property
    def installed_files(self) -> tuple[str, ...]:
        """Names in a published installation, besides the install record."""
        if self.conversion is not None:
            return self.conversion.outputs
        return tuple(f.path for f in self.files)


def parse_manifest(data: bytes) -> Manifest:
    """Parse and validate manifest bytes; the digest is their SHA-256."""
    failure = "manifest_invalid"
    manifest = None
    try:
        if "digest" not in json.loads(data):
            manifest = Manifest.model_validate_json(data)
    except ValidationError as error:
        errors = [str(e.get("ctx", {}).get("error")) for e in error.errors()]
        if "manifest_pickle" in errors:
            failure = "manifest_pickle"
    except (ValueError, TypeError):
        pass
    if manifest is None:
        raise ManifestError(failure)
    return manifest.model_copy(update={"digest": hashlib.sha256(data).hexdigest()})


@cache
def load_manifest(model_id: str) -> Manifest:
    """The tracked manifest for a configured model alias."""
    package = resources.files("hagig") / "manifests"
    data = None
    if model_id in get_args(ModelId):
        data = (package / f"{model_id}.json").read_bytes()
    if data is None:
        raise ManifestError("unknown_model")
    manifest = parse_manifest(data)
    if manifest.id != model_id:
        raise ManifestError("manifest_invalid")
    return manifest
