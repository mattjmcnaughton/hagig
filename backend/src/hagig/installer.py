"""Explicit model installation: `hagig model install` (TDD section 4).

The only network step in Hagig, run in the CLI process and never by the server
or worker. Under a persistent install lock it downloads exactly the manifest's
files from their pinned URLs over httpx into a model-only staging directory,
verifying each size and SHA-256 while streaming. Whisper's pinned `convert.py`
is downloaded and verified the same way, then run by this interpreter, offline,
to produce the MLX files, whose hashes the install record keeps.

Publishing is two renames: the finished directory becomes an immutable
`<id>/v-<hex>`, then a new `current` symlink replaces the old one. A failure or
interruption at any point leaves the previous `current` and its files as they
were; leftovers are removed by the next install. After a publish, versions
other than `current` are removed. A worker that already loaded an older
version keeps its open files; a load racing the swap fails closed.

No Hugging Face Hub client, cache or token is used. Redirects are followed
only to the allowed origins (Hugging Face's CDN), at most five times. Errors
carry a stable code and at most a manifest file name, never a URL or path.
"""

import contextlib
import hashlib
import os
import secrets
import shutil
import stat
import subprocess
import sys
import tempfile
from collections.abc import Callable, Mapping
from pathlib import Path
from typing import Literal

import httpx

from hagig.launcher import worker_env
from hagig.manifest import Manifest
from hagig.models import (
    CURRENT,
    LOCK_NAME,
    RECORD_NAME,
    STAGING_PREFIX,
    ModelError,
    Record,
    current_version,
    installed_model,
    verify_installation,
)
from hagig.paths import PathError, ServerLock

MAX_REDIRECTS = 5
CONVERT_SECONDS = 1800.0
_CHUNK = 1 << 20
_HOSTS = frozenset({"huggingface.co", "raw.githubusercontent.com"})
_HOST_SUFFIXES = (".hf.co", ".huggingface.co")

Result = Literal["installed", "already_installed"]
# (event, manifest file name): "download", "convert", "verify".
Progress = Callable[[str, str | None], None]


class InstallError(Exception):
    """An install failed. `code` is stable; `file` is a manifest file name."""

    def __init__(self, code: str, file: str | None = None) -> None:
        super().__init__(code if file is None else f"{code}: {file}")
        self.code = code
        self.file = file


def official_origin(url: httpx.URL) -> bool:
    """HTTPS to Hugging Face (and its CDN) or raw.githubusercontent.com."""
    host = url.host
    return (
        url.scheme == "https"
        and url.port is None
        and (host in _HOSTS or host.endswith(_HOST_SUFFIXES))
    )


def _quiet(event: str, name: str | None) -> None:
    pass


def install(
    manifest: Manifest,
    models_root: Path,
    *,
    client: httpx.Client,
    env: Mapping[str, str],
    apple_silicon: bool,
    python: str = sys.executable,
    allow: Callable[[httpx.URL], bool] = official_origin,
    progress: Progress = _quiet,
    convert_seconds: float = CONVERT_SECONDS,
) -> Result:
    """Install `manifest` under `models_root`, or keep a valid installation.

    `client` must not follow redirects itself. `env` supplies the converter's
    HOME and TMPDIR (it runs with the worker's offline environment).
    """
    if manifest.apple_silicon_only and not apple_silicon:
        raise InstallError("model_unsupported_on_platform")
    failure = None
    lock = None
    try:
        models_root.mkdir(parents=True, mode=0o700, exist_ok=True)
        lock = ServerLock.acquire(models_root, name=LOCK_NAME)
    except PathError as error:
        failure = error.code
    except OSError:
        failure = "install_failed"
    if failure is not None:
        raise InstallError(failure)
    if lock is None:
        raise InstallError("install_in_progress")
    outcome = None
    try:
        outcome = _Install(
            manifest, models_root, client, env, python, allow, progress
        ).run(convert_seconds)
    except OSError:
        pass
    finally:
        lock.release()
    if outcome is None:
        # A filesystem error outside the download path; its text has paths.
        raise InstallError("install_failed")
    return outcome


class _Install:
    def __init__(
        self,
        manifest: Manifest,
        models_root: Path,
        client: httpx.Client,
        env: Mapping[str, str],
        python: str,
        allow: Callable[[httpx.URL], bool],
        progress: Progress,
    ) -> None:
        self.manifest = manifest
        self.models_root = models_root
        self.base = models_root / manifest.id
        self.client = client
        self.env = env
        self.python = python
        self.allow = allow
        self.progress = progress

    def run(self, convert_seconds: float) -> Result:
        # The lock is held, so any staging directory is an interrupted install.
        for leftover in self.models_root.glob(STAGING_PREFIX + "*"):
            shutil.rmtree(leftover, ignore_errors=True)
        self._ensure_model_dir()
        if self._installed():
            self._prune()
            return "already_installed"
        staging = Path(tempfile.mkdtemp(prefix=STAGING_PREFIX, dir=self.models_root))
        try:
            content = self._stage(staging, convert_seconds)
            self._publish(content)
        finally:
            shutil.rmtree(staging, ignore_errors=True)
        self._prune()
        return "installed"

    def _ensure_model_dir(self) -> None:
        unsafe = False
        try:
            unsafe = not stat.S_ISDIR(os.lstat(self.base).st_mode)
        except FileNotFoundError:
            os.mkdir(self.base, 0o700)
        if unsafe:
            raise InstallError("model_dir_unsafe")

    def _installed(self) -> bool:
        self.progress("verify", None)
        try:
            verify_installation(installed_model(self.models_root, self.manifest))
        except ModelError:
            return False
        return True

    def _stage(self, staging: Path, convert_seconds: float) -> Path:
        manifest = self.manifest
        files = staging / "files"
        files.mkdir(mode=0o700)
        for entry in manifest.files:
            self.progress("download", entry.path)
            self._download(
                manifest.source.download + entry.path,
                files / entry.path,
                entry.size,
                entry.sha256,
                entry.path,
            )
        conversion = manifest.conversion
        if conversion is None:
            hashes = {f.path: (f.size, f.sha256) for f in manifest.files}
            return self._seal(files, hashes)
        tool = staging / "convert.py"
        self.progress("download", "convert.py")
        self._download(
            conversion.url, tool, conversion.size, conversion.sha256, "convert.py"
        )
        output = staging / "output"
        self.progress("convert", None)
        argv = [
            self.python,
            "-I",
            str(tool),
            "--torch-name-or-path",
            str(files),
            "--mlx-path",
            str(output),
            *conversion.arguments,
        ]
        returncode = None
        with contextlib.suppress(OSError, subprocess.TimeoutExpired):
            returncode = subprocess.run(
                argv,
                cwd=staging,
                env=worker_env(self.env),
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=convert_seconds,
                check=False,
            ).returncode
        if returncode != 0:
            raise InstallError("conversion_failed")
        hashes = _hash_outputs(output, conversion.outputs)
        if hashes is None:
            raise InstallError("conversion_output_invalid")
        return self._seal(output, hashes)

    def _seal(self, content: Path, hashes: dict[str, tuple[int, str]]) -> Path:
        record = Record(self.manifest.id, self.manifest.digest, hashes)
        fd = os.open(content / RECORD_NAME, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            os.write(fd, record.to_json())
            os.fsync(fd)
        finally:
            os.close(fd)
        _fsync(content)
        return content

    def _download(
        self, url: str, dest: Path, size: int, digest: str, name: str
    ) -> None:
        target = httpx.URL(url)
        code = None
        hasher = hashlib.sha256()
        fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            for hop in range(MAX_REDIRECTS + 1):
                if not self.allow(target):
                    code = (
                        "download_redirect_refused"
                        if hop
                        else "download_origin_refused"
                    )
                    break
                code, target = self._fetch(target, fd, size, hasher)
                if target is None:
                    break
            else:
                code = "download_redirect_refused"
            if code is None:
                os.fsync(fd)
        finally:
            os.close(fd)
        if code is None and hasher.hexdigest() != digest:
            code = "download_hash_mismatch"
        if code is not None:
            raise InstallError(code, name)

    def _fetch(
        self, url: httpx.URL, fd: int, size: int, hasher: "hashlib._Hash"
    ) -> tuple[str | None, httpx.URL | None]:
        """One request: (failure code, redirect target)."""
        try:
            with self.client.stream(
                "GET", url, headers={"Accept-Encoding": "identity"}
            ) as response:
                if response.is_redirect:
                    location = response.headers.get("location")
                    if not location:
                        return "download_failed", None
                    return None, url.join(location)
                if response.status_code != 200:
                    return "download_failed", None
                declared = response.headers.get("content-length")
                if declared is not None and declared != str(size):
                    return "download_size_mismatch", None
                total = 0
                for chunk in response.iter_raw(_CHUNK):
                    total += len(chunk)
                    if total > size:
                        return "download_size_mismatch", None
                    hasher.update(chunk)
                    _write_all(fd, chunk)
                if total != size:
                    return "download_size_mismatch", None
        except httpx.HTTPError:
            return "download_failed", None
        except OSError:
            return "install_failed", None
        return None, None

    def _publish(self, content: Path) -> None:
        version = self.base / f"v-{secrets.token_hex(16)}"
        link = self.base / f".current-{secrets.token_hex(8)}"
        failed = False
        try:
            os.rename(content, version)
            os.symlink(version.name, link)
            os.replace(link, self.base / CURRENT)
            _fsync(self.base)
        except OSError:
            failed = True
        if failed:
            raise InstallError("install_failed")

    def _prune(self) -> None:
        current = current_version(self.models_root, self.manifest.id)
        keep = {CURRENT, current.name if current else ""}
        for entry in os.scandir(self.base):
            if entry.name in keep:
                continue
            if entry.is_dir(follow_symlinks=False):
                shutil.rmtree(entry.path, ignore_errors=True)
            else:
                with contextlib.suppress(OSError):
                    os.unlink(entry.path)


def _write_all(fd: int, data: bytes) -> None:
    view = memoryview(data)
    while view:
        view = view[os.write(fd, view) :]


def _fsync(directory: Path) -> None:
    fd = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _hash_outputs(
    output: Path, names: tuple[str, ...]
) -> dict[str, tuple[int, str]] | None:
    """Hash exactly the converter's expected outputs, or None if they differ."""
    try:
        present = {entry.name for entry in os.scandir(output)}
    except OSError:
        return None
    if present != set(names):
        return None
    hashes = {}
    for name in names:
        try:
            fd = os.open(output / name, os.O_RDONLY | os.O_NOFOLLOW)
        except OSError:
            return None
        hasher = hashlib.sha256()
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_size == 0:
                return None
            while chunk := os.read(fd, _CHUNK):
                hasher.update(chunk)
            os.fsync(fd)
        finally:
            os.close(fd)
        hashes[name] = (info.st_size, hasher.hexdigest())
    return hashes
