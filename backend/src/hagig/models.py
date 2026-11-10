"""Installed models: layout, install record and load-time checks (TDD 2-4).

`hagig model install` (`hagig.installer`) is the only writer. Layout under the
models directory (`$XDG_DATA_HOME/hagig/models`):

    .install.lock            persistent install lock, never unlinked
    .staging-*/              an install in progress (model files only)
    <id>/current -> v-<hex>  the published version, swapped atomically
    <id>/v-<hex>/            immutable: the engine's files + hagig-install.json

The install record lists every installed file with its size and SHA-256 and
the digest of the manifest it was installed from. Converted MLX files are
hashed at install, so the record is where their hashes live.

Two checks, both read-only and offline; neither ever acquires anything:

- `installed_model` (server, before every worker launch): cheap and bounded.
  It reads one symlink and the small record, compares the record with the
  tracked manifest, and checks the directory holds exactly the recorded
  files at their recorded sizes. It never hashes.
- `verify_installation` (worker, at every `load`): hashes every recorded file.

This module is stdlib only, because the worker imports it. Errors are stable
codes with no paths or OS text.
"""

import hashlib
import json
import os
import re
import stat
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from hagig.manifest import Manifest

RECORD_NAME = "hagig-install.json"
CURRENT = "current"
LOCK_NAME = ".install.lock"
STAGING_PREFIX = ".staging-"
RECORD_FORMAT = 1
MAX_RECORD_BYTES = 64 * 1024
_VERSION = re.compile(r"v-[0-9a-f]{32}")
_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}")
_SHA256 = re.compile(r"[0-9a-f]{64}")
_CHUNK = 1 << 20


class ModelError(Exception):
    """`model_missing` or `model_invalid` (PROTOCOL.md)."""

    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


@dataclass(frozen=True)
class Record:
    manifest: str
    manifest_sha256: str
    # name -> (size, sha256)
    files: dict[str, tuple[int, str]]

    def to_json(self) -> bytes:
        files = [
            {"path": name, "size": size, "sha256": digest}
            for name, (size, digest) in sorted(self.files.items())
        ]
        document = {
            "format": RECORD_FORMAT,
            "manifest": self.manifest,
            "manifest_sha256": self.manifest_sha256,
            "files": files,
        }
        return json.dumps(document, indent=2).encode() + b"\n"


def is_version_name(name: str) -> bool:
    return _VERSION.fullmatch(name) is not None


def current_version(models_root: Path, model_id: str) -> Path | None:
    """The published version directory, or None when nothing is published.

    Raises `model_invalid` when the pointer is not one the installer writes.
    """
    target = None
    invalid = False
    try:
        target = os.readlink(models_root / model_id / CURRENT)
    except FileNotFoundError:
        pass
    except OSError:
        # EINVAL (not a symlink), ENOTDIR (<id> is not a directory), EACCES.
        invalid = True
    if invalid or (target is not None and not is_version_name(target)):
        raise ModelError("model_invalid")
    if target is None:
        return None
    return models_root / model_id / target


def model_present(models_root: Path, model_id: str) -> bool:
    """Whether anything is published for the alias (PROTOCOL.md's first check)."""
    return os.path.lexists(models_root / model_id / CURRENT)


def read_record(version: Path) -> Record:
    """Parse a version's install record, or raise `model_invalid`."""
    data = _read_small(version / RECORD_NAME)
    record = _parse_record(data) if data is not None else None
    if record is None:
        raise ModelError("model_invalid")
    return record


def installed_model(models_root: Path, manifest: "Manifest") -> Path:
    """The configured model's published version directory, checked cheaply.

    `model_missing` when nothing is published for the alias; `model_invalid`
    when the installation does not match the manifest, a file is absent, extra
    or a different size. Bounded: one readlink, one record of at most 64 KiB,
    one directory listing stopped after the expected count, one lstat per file.
    """
    version = current_version(models_root, manifest.id)
    if version is None:
        raise ModelError("model_missing")
    record = read_record(version)
    if not _matches_manifest(record, manifest):
        raise ModelError("model_invalid")
    expected = {*record.files, RECORD_NAME}
    seen = set()
    try:
        with os.scandir(version) as entries:
            for entry in entries:
                # Stops at the first unexpected entry, so the listing is bounded.
                if entry.name not in expected:
                    raise ModelError("model_invalid")
                seen.add(entry.name)
                info = entry.stat(follow_symlinks=False)
                size = record.files.get(entry.name, (info.st_size, ""))[0]
                if not stat.S_ISREG(info.st_mode) or info.st_size != size:
                    raise ModelError("model_invalid")
    except OSError:
        seen = set()
    if seen != expected:
        raise ModelError("model_invalid")
    return version


def verify_installation(version: Path) -> None:
    """Hash every recorded file (the worker's load-time check).

    `model_missing` when the record or a recorded file is absent;
    `model_invalid` when anything else differs from the record.
    """
    if not os.path.lexists(version / RECORD_NAME):
        raise ModelError("model_missing")
    record = read_record(version)
    for name, (size, digest) in record.files.items():
        code = _verify_file(version / name, size, digest)
        if code is not None:
            raise ModelError(code)


def _verify_file(path: Path, size: int, digest: str) -> str | None:
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except FileNotFoundError:
        return "model_missing"
    except OSError:
        return "model_invalid"
    hasher = hashlib.sha256()
    total = 0
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_size != size:
            return "model_invalid"
        while chunk := os.read(fd, _CHUNK):
            total += len(chunk)
            if total > size:
                return "model_invalid"
            hasher.update(chunk)
    except OSError:
        return "model_invalid"
    finally:
        os.close(fd)
    if total != size or hasher.hexdigest() != digest:
        return "model_invalid"
    return None


def _matches_manifest(record: Record, manifest: "Manifest") -> bool:
    if record.manifest != manifest.id or record.manifest_sha256 != manifest.digest:
        return False
    if set(record.files) != set(manifest.installed_files):
        return False
    if manifest.conversion is not None:
        # Converted files are hashed at install; the record is their pin.
        return True
    return all(record.files[f.path] == (f.size, f.sha256) for f in manifest.files)


def _read_small(path: Path) -> bytes | None:
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError:
        return None
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            return None
        data = os.read(fd, MAX_RECORD_BYTES + 1)
    except OSError:
        return None
    finally:
        os.close(fd)
    return data if len(data) <= MAX_RECORD_BYTES else None


def _parse_record(data: bytes) -> Record | None:
    try:
        document = json.loads(data)
    except ValueError:
        return None
    if not isinstance(document, dict) or set(document) != {
        "format",
        "manifest",
        "manifest_sha256",
        "files",
    }:
        return None
    manifest, digest, entries = (
        document["manifest"],
        document["manifest_sha256"],
        document["files"],
    )
    if (
        document["format"] != RECORD_FORMAT
        or not isinstance(manifest, str)
        or not isinstance(digest, str)
        or not _SHA256.fullmatch(digest)
        or not isinstance(entries, list)
        or not entries
    ):
        return None
    files: dict[str, tuple[int, str]] = {}
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != {"path", "size", "sha256"}:
            return None
        name, size, sha = entry["path"], entry["size"], entry["sha256"]
        if (
            not isinstance(name, str)
            or not _NAME.fullmatch(name)
            or name == RECORD_NAME
            or name in files
            or type(size) is not int
            or size <= 0
            or not isinstance(sha, str)
            or not _SHA256.fullmatch(sha)
        ):
            return None
        files[name] = (size, sha)
    return Record(manifest, digest, files)
