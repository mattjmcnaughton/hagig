"""Load-time checks on real installations (no installer involved)."""

import json
import os
import shutil
import threading

import pytest

from hagig.manifest import parse_manifest
from hagig.models import (
    ModelError,
    current_version,
    installed_model,
    model_present,
    verify_installation,
)
from tests.support.models import FILES, WEIGHTS, manifest_bytes, write_installation

MANIFEST = parse_manifest(manifest_bytes("https://h.example"))
VERSION = "v-" + "0" * 32


@pytest.fixture
def models(tmp_path):
    return tmp_path / "models"


@pytest.fixture
def version(models):
    return write_installation(models, MANIFEST, FILES, VERSION)


def error(check, *args):
    with pytest.raises(ModelError) as caught:
        check(*args)
    return caught.value.code


def test_a_valid_installation_passes_both_checks(models, version):
    assert model_present(models, MANIFEST.id)
    assert installed_model(models, MANIFEST) == version
    verify_installation(version)


def test_nothing_published_is_missing(models):
    assert not model_present(models, MANIFEST.id)
    assert error(installed_model, models, MANIFEST) == "model_missing"
    (models / MANIFEST.id).mkdir(parents=True)
    assert error(installed_model, models, MANIFEST) == "model_missing"


def damage_current(models, version, how):
    link = models / MANIFEST.id / "current"
    link.unlink()
    if how == "directory":
        link.mkdir()
    elif how == "absolute":
        os.symlink(version, link)
    elif how == "escape":
        os.symlink("../other", link)
    elif how == "dangling":
        os.symlink("v-" + "f" * 32, link)


@pytest.mark.parametrize("how", ["directory", "absolute", "escape", "dangling"])
def test_a_current_pointer_the_installer_never_writes_is_invalid(models, version, how):
    damage_current(models, version, how)
    assert model_present(models, MANIFEST.id)
    assert error(installed_model, models, MANIFEST) == "model_invalid"


def test_a_model_path_that_is_a_file_is_invalid(models):
    models.mkdir()
    (models / MANIFEST.id).write_text("")
    assert error(current_version, models, MANIFEST.id) == "model_invalid"


def rewrite_record(version, change):
    path = version / "hagig-install.json"
    record = json.loads(path.read_text())
    change(record)
    path.write_text(json.dumps(record))


@pytest.mark.parametrize(
    "damage",
    [
        "extra_file",
        "missing_file",
        "short_file",
        "long_file",
        "symlinked_file",
        "subdirectory",
        "record_absent",
        "record_garbage",
        "record_huge",
        "record_other_manifest",
        "record_other_digest",
        "record_other_hash",
        "record_extra_key",
        "record_fifo",
        "file_fifo",
        "version_writable_by_others",
        "id_writable_by_group",
        "version_symlinked",
    ],
)
def test_the_cheap_check_refuses_damage_it_can_see(models, version, damage):
    weights = version / "model.safetensors"
    record = version / "hagig-install.json"
    match damage:
        case "extra_file":
            (version / "notes.txt").write_text("x")
        case "missing_file":
            (version / "config.json").unlink()
        case "short_file":
            weights.write_bytes(WEIGHTS[:-1])
        case "long_file":
            weights.write_bytes(WEIGHTS + b"x")
        case "symlinked_file":
            weights.unlink()
            (models / "elsewhere").write_bytes(WEIGHTS)
            os.symlink(models / "elsewhere", weights)
        case "subdirectory":
            (version / "sub").mkdir()
        case "record_absent":
            record.unlink()
        case "record_garbage":
            record.write_bytes(b"\xff{")
        case "record_huge":
            record.write_bytes(b" " * (64 * 1024 + 1))
        case "record_other_manifest":
            rewrite_record(version, lambda r: r.update(manifest="qwen3-asr-1.7b"))
        case "record_other_digest":
            rewrite_record(version, lambda r: r.update(manifest_sha256="0" * 64))
        case "record_other_hash":
            rewrite_record(version, lambda r: r["files"][1].update(sha256="0" * 64))
        case "record_extra_key":
            rewrite_record(version, lambda r: r.update(extra=1))
        case "record_fifo":
            record.unlink()
            os.mkfifo(record)
        case "file_fifo":
            weights.unlink()
            os.mkfifo(weights)
        case "version_writable_by_others":
            version.chmod(0o757)
        case "id_writable_by_group":
            version.parent.chmod(0o775)
        case "version_symlinked":
            real = models / "elsewhere"
            version.rename(real)
            os.symlink(real, version)
    assert bounded(installed_model, models, MANIFEST) == "model_invalid"


def bounded(check, *args):
    """The check's error code; it must finish within 5 s (no blocking open)."""
    result = []
    thread = threading.Thread(target=lambda: result.append(error(check, *args)))
    thread.daemon = True
    thread.start()
    thread.join(5)
    assert not thread.is_alive(), "check blocked"
    return result[0]


def test_the_load_check_refuses_a_fifo_without_blocking(models, version):
    weights = version / "model.safetensors"
    weights.unlink()
    os.mkfifo(weights)
    assert bounded(verify_installation, version) == "model_invalid"


def test_the_cheap_check_does_not_hash_but_the_load_check_does(models, version):
    weights = version / "model.safetensors"
    weights.write_bytes(b"X" + WEIGHTS[1:])

    assert installed_model(models, MANIFEST) == version
    assert error(verify_installation, version) == "model_invalid"


def test_the_load_check_reports_absent_files_as_missing(models, version):
    (version / "config.json").unlink()
    assert error(verify_installation, version) == "model_missing"
    shutil.rmtree(version)
    assert error(verify_installation, version) == "model_missing"


def test_the_load_check_refuses_a_symlinked_file(models, version):
    weights = version / "model.safetensors"
    weights.unlink()
    (models / "elsewhere").write_bytes(WEIGHTS)
    os.symlink(models / "elsewhere", weights)
    assert error(verify_installation, version) == "model_invalid"


def test_a_converted_installation_is_pinned_by_its_record(models):
    from tests.support.models import CONVERTER

    manifest = parse_manifest(manifest_bytes("https://h.example", converter=CONVERTER))
    files = {"config.json": b"{}", "weights.safetensors": b"converted"}
    version = write_installation(models, manifest, files, VERSION)

    assert installed_model(models, manifest) == version
    verify_installation(version)
    # A source-format installation is not the converted layout.
    other = write_installation(models / "x", manifest, FILES, VERSION)
    assert error(installed_model, models / "x", manifest) == "model_invalid"
    assert other.exists()
