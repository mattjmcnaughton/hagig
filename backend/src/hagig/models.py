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

The models directory, each `<id>` and each version must be real directories
owned by this user and not writable by group or others (TDD section 3's
boundary is other OS users), else `model_invalid`.

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
INSTALL_LOCK_NAME = ".install.lock"
STAGING_PREFIX = ".staging-"
CURRENT_TMP_PREFIX = ".current-"
RECORD_FORMAT = 1
MAX_RECORD_BYTES = 64 * 1024
# Shared with the manifest schema, so manifests and records agree.
NAME_PATTERN = r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"
SHA256_PATTERN = r"^[0-9a-f]{64}$"
VERSION_PATTERN = re.compile(r"v-[0-9a-f]{32}")
_NAME = re.compile(NAME_PATTERN)
_SHA256 = re.compile(SHA256_PATTERN)
# O_NONBLOCK: opening a planted FIFO must not block; it is then refused.
_OPEN_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC


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


def hash_file(path: Path) -> tuple[int, str] | None:
    """(size, SHA-256) of a regular file, never following a symlink.

    None when the path is not a regular file. Raises FileNotFoundError when
    it is absent and OSError for other failures (a symlink is ELOOP).
    """
    fd = os.open(path, _OPEN_FLAGS)
    with os.fdopen(fd, "rb") as file:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            return None
        return info.st_size, hashlib.file_digest(file, "sha256").hexdigest()


def private_dir(path: Path, uid: int | None = None) -> bool:
    """A real directory owned by `uid`, not writable by group or others."""
    try:
        info = os.lstat(path)
    except OSError:
        return False
    return (
        stat.S_ISDIR(info.st_mode)
        and info.st_uid == (os.getuid() if uid is None else uid)
        and not info.st_mode & 0o022
    )


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
    if invalid or (target is not None and not VERSION_PATTERN.fullmatch(target)):
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
    when a directory is unsafe, or the installation does not match the
    manifest, a file is absent, extra, not regular or a different size.
    Bounded: one readlink, three lstats, one record of at most 64 KiB, one
    directory listing that stops at the first unexpected entry, one lstat per
    file. It never hashes.
    """
    version = current_version(models_root, manifest.id)
    if version is None:
        raise ModelError("model_missing")
    if not all(map(private_dir, (models_root, version.parent, version))):
        raise ModelError("model_invalid")
    record = read_record(version)
    if not _matches_manifest(record, manifest) or not _holds_exactly(version, record):
        raise ModelError("model_invalid")
    return version


def _holds_exactly(version: Path, record: Record) -> bool:
    """The directory holds the record and the recorded files at their sizes."""
    seen = set()
    try:
        with os.scandir(version) as entries:
            for entry in entries:
                info = entry.stat(follow_symlinks=False)
                if entry.name == RECORD_NAME:
                    expected_size = info.st_size
                elif entry.name in record.files:
                    expected_size = record.files[entry.name][0]
                else:
                    return False
                if not stat.S_ISREG(info.st_mode) or info.st_size != expected_size:
                    return False
                seen.add(entry.name)
    except OSError:
        return False
    return seen == {*record.files, RECORD_NAME}


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
        found = hash_file(path)
    except FileNotFoundError:
        return "model_missing"
    except OSError:
        return "model_invalid"
    return None if found == (size, digest) else "model_invalid"


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
        fd = os.open(path, _OPEN_FLAGS)
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
