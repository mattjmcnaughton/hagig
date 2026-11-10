"""TOML configuration (TDD section 3).

Read only from `config.toml` with stdlib `tomllib`, validated by strict
pydantic models; there are no environment-variable overrides. Errors name the
field and a stable code, never the offending value, an unknown key's name, or
pydantic's messages (which echo input).
"""

import platform
import tomllib
import unicodedata
from dataclasses import dataclass
from pathlib import Path
from typing import Annotated, Any, Literal, get_args

from pydantic import (
    AfterValidator,
    BaseModel,
    ConfigDict,
    ValidationError,
    ValidationInfo,
    field_validator,
)
from pydantic_core import PydanticCustomError

EditorMode = Literal["standard", "vim"]
ModelId = Literal["qwen3-asr-0.6b", "qwen3-asr-1.7b", "whisper-large-v3-turbo"]
NetworkIsolation = Literal["required", "disabled"]

# PROVISIONAL, not a chosen default: TDD section 13 leaves the default engine
# and Qwen3-ASR size to a physical-Mac run. Change it here only.
PROVISIONAL_DEFAULT_MODEL_ID: ModelId = "qwen3-asr-0.6b"
APPLE_SILICON_ONLY_MODEL_IDS = frozenset({"whisper-large-v3-turbo"})

IssueCode = Literal[
    "unknown_key",
    "invalid_value",
    "invalid_type",
    "too_many",
    "too_long",
    "too_large",
    "model_unsupported_on_platform",
]
_ISSUE_CODES = frozenset(get_args(IssueCode))

# Far above any real file (vocabulary is capped at 16 KiB); bounds the read.
MAX_CONFIG_BYTES = 1024 * 1024
MAX_TERMS = 200
MAX_TERM_CHARS = 100
MAX_TERMS_UTF8_BYTES = 16 * 1024
# Terms are embedded in model prompts, so no control or line-break characters.
_FORBIDDEN_CATEGORIES = frozenset({"Cc", "Zl", "Zp"})


def is_apple_silicon() -> bool:
    return platform.system() == "Darwin" and platform.machine() == "arm64"


def _fail(code: IssueCode) -> PydanticCustomError:
    return PydanticCustomError(code, code)


def _term(value: str) -> str:
    term = value.strip()
    if not term or any(unicodedata.category(c) in _FORBIDDEN_CATEGORIES for c in term):
        raise _fail("invalid_value")
    if len(term) > MAX_TERM_CHARS:
        raise _fail("too_long")
    return term


def _terms(terms: list[str]) -> list[str]:
    if len(terms) > MAX_TERMS:
        raise _fail("too_many")
    if sum(len(term.encode()) for term in terms) > MAX_TERMS_UTF8_BYTES:
        raise _fail("too_large")
    return terms


_TABLE = ConfigDict(extra="forbid", strict=True, frozen=True)


class EditorConfig(BaseModel):
    model_config = _TABLE
    mode: EditorMode = "standard"


class ModelConfig(BaseModel):
    model_config = _TABLE
    id: ModelId = PROVISIONAL_DEFAULT_MODEL_ID

    @field_validator("id")
    @classmethod
    def _platform(cls, value: ModelId, info: ValidationInfo) -> ModelId:
        # load_config always supplies the platform; without it, fail closed.
        apple_silicon = (info.context or {}).get("apple_silicon", False)
        if value in APPLE_SILICON_ONLY_MODEL_IDS and not apple_silicon:
            raise _fail("model_unsupported_on_platform")
        return value


class InferenceConfig(BaseModel):
    model_config = _TABLE
    network_isolation: NetworkIsolation = "required"


class VocabularyConfig(BaseModel):
    model_config = _TABLE
    terms: Annotated[
        list[Annotated[str, AfterValidator(_term)]], AfterValidator(_terms)
    ] = []


class Config(BaseModel):
    model_config = _TABLE
    editor: EditorConfig = EditorConfig()
    model: ModelConfig = ModelConfig()
    inference: InferenceConfig = InferenceConfig()
    vocabulary: VocabularyConfig = VocabularyConfig()


@dataclass(frozen=True)
class ConfigIssue:
    field: str
    code: str


class ConfigError(Exception):
    """Configuration was rejected. Every part is content-free.

    `code` is `config_unreadable`, `config_too_large`, `config_syntax` or
    `config_invalid`; the last carries `issues`.
    """

    def __init__(self, code: str, issues: tuple[ConfigIssue, ...] = ()) -> None:
        details = "; ".join(f"{issue.field} {issue.code}" for issue in issues)
        super().__init__(f"{code}: {details}" if details else code)
        self.code = code
        self.issues = issues


# Each step raises its ConfigError after leaving the except block, so no
# content-bearing OS, TOML or pydantic exception is chained onto it.


def load_config(path: Path, *, apple_silicon: bool | None = None) -> Config:
    """Load and validate configuration. A missing file means all defaults."""
    if apple_silicon is None:
        apple_silicon = is_apple_silicon()
    data = _parse(_read(path))
    try:
        return Config.model_validate(data, context={"apple_silicon": apple_silicon})
    except ValidationError as error:
        issues = _issues(error)
    raise ConfigError("config_invalid", issues)


def _read(path: Path) -> bytes:
    try:
        with open(path, "rb") as handle:
            raw = handle.read(MAX_CONFIG_BYTES + 1)
    except FileNotFoundError:
        return b""
    except OSError:
        raw = None
    if raw is None:
        raise ConfigError("config_unreadable")
    if len(raw) > MAX_CONFIG_BYTES:
        raise ConfigError("config_too_large")
    return raw


def _parse(raw: bytes) -> dict[str, Any]:
    try:
        return tomllib.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, tomllib.TOMLDecodeError, RecursionError):
        pass
    raise ConfigError("config_syntax")


def _issues(error: ValidationError) -> tuple[ConfigIssue, ...]:
    issues = []
    for detail in error.errors(include_url=False, include_context=False):
        loc = detail["loc"]
        kind = detail["type"]
        if kind == "extra_forbidden":
            # The unknown key is user input; name only its table.
            issues.append(ConfigIssue(_field(loc[:-1]), "unknown_key"))
        elif kind == "literal_error":
            code = (
                "invalid_value" if isinstance(detail["input"], str) else "invalid_type"
            )
            issues.append(ConfigIssue(_field(loc), code))
        elif kind.endswith("_type"):
            issues.append(ConfigIssue(_field(loc), "invalid_type"))
        elif kind in _ISSUE_CODES:
            issues.append(ConfigIssue(_field(loc), kind))
        else:
            issues.append(ConfigIssue(_field(loc), "invalid_value"))
    return tuple(issues)


def _field(loc: tuple[int | str, ...]) -> str:
    parts = (f"[{part}]" if isinstance(part, int) else f".{part}" for part in loc)
    return "".join(parts).lstrip(".") or "<root>"
