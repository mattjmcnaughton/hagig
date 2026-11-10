"""Explicit model installation: `hagig model install` (TDD section 4).

The only network step in Hagig, run in the CLI process and never by the server
or worker. Under a persistent install lock it downloads exactly the manifest's
files from their pinned URLs over httpx into a model-only staging directory,
verifying each size and SHA-256 while streaming. Whisper's pinned `convert.py`
is downloaded and verified the same way, then run by this interpreter, offline,
to produce the MLX files, whose hashes the install record keeps. The CLI owns
the platform and engine preflight; this module installs what it is given.

Publishing is two renames: the finished directory becomes an immutable
`<id>/v-<hex>`, then a new `current` symlink replaces the old one. A failure or
interruption at any point leaves the previous `current` and its files as they
were; leftovers are removed by the next install. After a publish, versions
other than `current` are removed; anything else in `<id>/` is left alone. A
worker that already loaded an older version keeps its open files; a load
racing the swap fails closed.

No Hugging Face Hub client, cache or token is used. Redirects are followed
only to the allowed origins (Hugging Face's CDN), at most five times. Errors
carry a stable code and at most a manifest file name, never a URL or path.
"""

import contextlib
import hashlib
import os
import secrets
import shutil
import subprocess
import sys
import tempfile
from collections.abc import Callable, Mapping
from pathlib import Path
from typing import BinaryIO, Literal

import httpx

from hagig.launcher import worker_env
from hagig.manifest import Manifest
from hagig.models import (
    CURRENT,
    CURRENT_TMP_PREFIX,
    INSTALL_LOCK_NAME,
    RECORD_NAME,
    STAGING_PREFIX,
    VERSION_PATTERN,
    ModelError,
    Record,
    current_version,
    hash_file,
    installed_model,
    private_dir,
    verify_installation,
)
from hagig.paths import PathError, ServerLock

MAX_REDIRECTS = 5
CONVERT_SECONDS = 1800.0
_CHUNK = 1 << 20
_HOSTS = frozenset({"huggingface.co", "raw.githubusercontent.com"})
_HOST_SUFFIXES = (".hf.co", ".huggingface.co")
# httpx failures, including the ones outside HTTPError (invalid URLs, stream
# misuse) and IDNA errors from a malformed redirect host (a ValueError).
_HTTP_ERRORS = (httpx.HTTPError, httpx.InvalidURL, httpx.StreamError, ValueError)

Result = Literal["installed", "already_installed"]
# (event, manifest file name): "verify", "download", "convert".
Progress = Callable[[str, str | None], None]


class InstallError(Exception):
    """An install failed. `code` is stable; `file` is a manifest file name."""

    def __init__(self, code: str, file: str | None = None) -> None:
        super().__init__(code if file is None else f"{code}: {file}")
        self.code = code
        self.file = file


def official_origin(url: httpx.URL) -> bool:
    """HTTPS on the default port to Hugging Face (and its CDN) or GitHub raw."""
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
    allow: Callable[[httpx.URL], bool] = official_origin,
    progress: Progress = _quiet,
) -> Result:
    """Install `manifest` under `models_root`, or keep a valid installation.

    `client` must not follow redirects itself. `env` supplies the converter's
    HOME and TMPDIR (it runs with the worker's offline environment). Any
    filesystem error is `install_failed`, raised without its OS text.
    """
    outcome: Result | None = None
    failure = "install_failed"
    lock = None
    try:
        models_root.mkdir(parents=True, mode=0o700, exist_ok=True)
        if not private_dir(models_root):
            raise InstallError("model_dir_unsafe")
        lock = ServerLock.acquire(models_root, name=INSTALL_LOCK_NAME)
        if lock is None:
            raise InstallError("install_in_progress")
        outcome = _Install(manifest, models_root, client, env, allow, progress).run()
    except PathError as error:
        failure = error.code
    except OSError:
        pass
    finally:
        if lock is not None:
            lock.release()
    if outcome is None:
        raise InstallError(failure)
    return outcome


class _Install:
    """One install under the lock; its methods share these inputs."""

    def __init__(
        self,
        manifest: Manifest,
        models_root: Path,
        client: httpx.Client,
        env: Mapping[str, str],
        allow: Callable[[httpx.URL], bool],
        progress: Progress,
    ) -> None:
        self.manifest = manifest
        self.models_root = models_root
        self.base = models_root / manifest.id
        self.client = client
        self.env = env
        self.allow = allow
        self.progress = progress

    def run(self) -> Result:
        # The lock is held, so any staging directory is an interrupted install.
        for leftover in self.models_root.glob(STAGING_PREFIX + "*"):
            shutil.rmtree(leftover, ignore_errors=True)
        with contextlib.suppress(FileExistsError):
            os.mkdir(self.base, 0o700)
        if not private_dir(self.base):
            raise InstallError("model_dir_unsafe")
        self.progress("verify", None)
        if self._installed():
            self._prune()
            return "already_installed"
        staging = Path(tempfile.mkdtemp(prefix=STAGING_PREFIX, dir=self.models_root))
        try:
            self._publish(self._stage(staging))
        finally:
            shutil.rmtree(staging, ignore_errors=True)
        self._prune()
        return "installed"

    def _installed(self) -> bool:
        try:
            verify_installation(installed_model(self.models_root, self.manifest))
        except ModelError:
            return False
        return True

    def _stage(self, staging: Path) -> Path:
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
            return self._seal(
                files, {f.path: (f.size, f.sha256) for f in manifest.files}
            )
        tool = staging / "convert.py"
        self.progress("download", "convert.py")
        self._download(
            conversion.url, tool, conversion.size, conversion.sha256, "convert.py"
        )
        output = staging / "output"
        self.progress("convert", None)
        returncode = None
        with contextlib.suppress(OSError, subprocess.TimeoutExpired):
            returncode = subprocess.run(
                [
                    sys.executable,
                    "-I",
                    str(tool),
                    "--torch-name-or-path",
                    str(files),
                    "--mlx-path",
                    str(output),
                    *conversion.arguments,
                ],
                cwd=staging,
                env=worker_env(self.env),
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=CONVERT_SECONDS,
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
        # A buffered write either writes everything or raises (e.g. ENOSPC).
        with open(content / RECORD_NAME, "xb", opener=_private_opener) as out:
            out.write(record.to_json())
            out.flush()
            os.fsync(out.fileno())
        _fsync(content)
        return content

    def _download(
        self, url: str, dest: Path, size: int, digest: str, name: str
    ) -> None:
        target: httpx.URL | None = httpx.URL(url)
        hasher = hashlib.sha256()
        with open(dest, "xb", opener=_private_opener) as out:
            for hop in range(MAX_REDIRECTS + 1):
                assert target is not None
                if not self.allow(target):
                    refused = (
                        "download_redirect_refused"
                        if hop
                        else "download_origin_refused"
                    )
                    raise InstallError(refused, name)
                target = self._fetch(target, out, size, hasher, name)
                if target is None:
                    break
            else:
                raise InstallError("download_redirect_refused", name)
            out.flush()
            os.fsync(out.fileno())
        if hasher.hexdigest() != digest:
            raise InstallError("download_hash_mismatch", name)

    def _fetch(
        self,
        url: httpx.URL,
        out: BinaryIO,
        size: int,
        hasher: "hashlib._Hash",
        name: str,
    ) -> httpx.URL | None:
        """One GET: the redirect target, or None once the whole body is written."""
        failed = False
        try:
            with self.client.stream(
                "GET", url, headers={"Accept-Encoding": "identity"}
            ) as response:
                location = response.headers.get("location")
                if response.is_redirect and location:
                    return url.join(location)
                if response.status_code != 200:
                    raise InstallError("download_failed", name)
                if response.headers.get("content-length", str(size)) != str(size):
                    raise InstallError("download_size_mismatch", name)
                total = 0
                for chunk in response.iter_raw(_CHUNK):
                    total += len(chunk)
                    if total > size:
                        raise InstallError("download_size_mismatch", name)
                    hasher.update(chunk)
                    out.write(chunk)
                if total != size:
                    raise InstallError("download_size_mismatch", name)
        except _HTTP_ERRORS:
            failed = True
        if failed:
            raise InstallError("download_failed", name)
        return None

    def _publish(self, content: Path) -> None:
        version = self.base / f"v-{secrets.token_hex(16)}"
        link = self.base / f"{CURRENT_TMP_PREFIX}{secrets.token_hex(8)}"
        os.rename(content, version)
        os.symlink(version.name, link)
        os.replace(link, self.base / CURRENT)
        _fsync(self.base)

    def _prune(self) -> None:
        """Remove what earlier installs left: other versions and temp links."""
        current = current_version(self.models_root, self.manifest.id)
        for entry in os.scandir(self.base):
            if current is not None and entry.name == current.name:
                continue
            if VERSION_PATTERN.fullmatch(entry.name) and entry.is_dir(
                follow_symlinks=False
            ):
                shutil.rmtree(entry.path, ignore_errors=True)
            elif entry.name.startswith(CURRENT_TMP_PREFIX) and entry.is_symlink():
                with contextlib.suppress(OSError):
                    os.unlink(entry.path)


def _private_opener(path: str, flags: int) -> int:
    return os.open(path, flags | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)


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
        if {entry.name for entry in os.scandir(output)} != set(names):
            return None
        hashes = {name: hash_file(output / name) for name in names}
    except OSError:
        return None
    if any(found is None or found[0] == 0 for found in hashes.values()):
        return None
    return {name: found for name, found in hashes.items() if found is not None}
