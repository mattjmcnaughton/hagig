"""Tracked manifests and strict manifest parsing."""

import json
from typing import get_args

import pytest

from hagig.config import ModelId
from hagig.manifest import ManifestError, load_manifest, parse_manifest
from tests.support.models import CONVERTER, manifest_bytes

# Pins from spike/inference-s2 (spikes/inference-s2/*.py) and the ticket.
PINS = {
    "qwen3-asr-0.6b": (
        "Qwen/Qwen3-ASR-0.6B-hf",
        "7f1569a48a89f3e3f4dc3a5c9d28bddd903bc76c",
        "d3f212dd20abecd315d830bc54ae3865e56ebfc3276484e57b771288ba27fd35",
    ),
    "qwen3-asr-1.7b": (
        "Qwen/Qwen3-ASR-1.7B-hf",
        "bcd2b5b7f32b480ab5790554cfa8347f246a14f3",
        "2db53c7d81bd9b8cbc6a074e89be2c968a0d373fb4ee68bb1b1e14f7042dfee1",
    ),
    "whisper-large-v3-turbo": (
        "openai/whisper-large-v3-turbo",
        "41f01f3fe87f28c78e2fbf8b568835947dd65ed9",
        "542566a422ae4f3fd23f1ba11add198fca01bbf82e66e6a2857b3f608b1eb9d1",
    ),
}
QWEN_FILES = {
    "chat_template.jinja",
    "config.json",
    "generation_config.json",
    "model.safetensors",
    "processor_config.json",
    "tokenizer.json",
    "tokenizer_config.json",
}


@pytest.mark.parametrize("model_id", get_args(ModelId))
def test_every_alias_has_a_pinned_manifest(model_id):
    manifest = load_manifest(model_id)
    repository, revision, weights = PINS[model_id]
    assert manifest.id == model_id
    assert (manifest.source.repository, manifest.source.revision) == (
        repository,
        revision,
    )
    assert manifest.source.download == (
        f"https://huggingface.co/{repository}/resolve/{revision}/"
    )
    sha = {f.path: f.sha256 for f in manifest.files}
    assert sha["model.safetensors"] == weights
    assert manifest.source.license and manifest.source.license_url.startswith("https")


def test_qwen_manifests_cover_every_loadable_file():
    for model_id in ("qwen3-asr-0.6b", "qwen3-asr-1.7b"):
        manifest = load_manifest(model_id)
        assert manifest.engine == "qwen3-asr"
        assert {f.path for f in manifest.files} == QWEN_FILES
        assert set(manifest.installed_files) == QWEN_FILES
        assert manifest.conversion is None and not manifest.apple_silicon_only


def test_whisper_manifest_pins_apples_converter():
    manifest = load_manifest("whisper-large-v3-turbo")
    conversion = manifest.conversion
    assert manifest.engine == "mlx-whisper" and manifest.apple_silicon_only
    assert conversion is not None
    assert conversion.commit == "c1af8c46bd4c4704cff1561736a634cee38efc6c"
    assert conversion.sha256 == (
        "9d5a03b60843e89512d1f825a6a6ee662fa2d17af347220c5e6a8b69af7574aa"
    )
    assert conversion.url == (
        "https://raw.githubusercontent.com/ml-explore/mlx-examples/"
        "c1af8c46bd4c4704cff1561736a634cee38efc6c/whisper/convert.py"
    )
    assert conversion.arguments == ("--dtype", "float16")
    assert manifest.installed_files == ("config.json", "weights.safetensors")


def test_the_digest_is_the_hash_of_the_manifest_bytes():
    data = manifest_bytes("https://huggingface.co")
    reformatted = json.dumps(json.loads(data), indent=4).encode()
    assert parse_manifest(data).digest != parse_manifest(reformatted).digest


def test_unknown_aliases_are_refused():
    with pytest.raises(ManifestError) as caught:
        load_manifest("../qwen3-asr-0.6b")
    assert caught.value.code == "unknown_model"


def edit(change, converter=None):
    document = json.loads(manifest_bytes("https://h.example", converter=converter))
    change(document)
    return json.dumps(document).encode()


@pytest.mark.parametrize(
    ("change", "code"),
    [
        (lambda d: d["files"].append({**d["files"][0], "path": "x.bin"}), "pickle"),
        (
            lambda d: d["files"].__setitem__(1, {**d["files"][1], "path": "m.pt"}),
            "pickle",
        ),
        # Pickle only: the safetensors weights are absent.
        (lambda d: d["files"].pop(1), "pickle"),
        (lambda d: d["files"].append(dict(d["files"][0])), "invalid"),
        (lambda d: d["files"][0].update(path="../config.json"), "invalid"),
        (lambda d: d["files"][0].update(path="sub/config.json"), "invalid"),
        (lambda d: d["files"][0].update(path="hagig-install.json"), "invalid"),
        (lambda d: d["files"][0].update(sha256="ABC"), "invalid"),
        (lambda d: d["files"][0].update(size=0), "invalid"),
        (lambda d: d["source"].update(revision="main"), "invalid"),
        (lambda d: d["source"].update(download="https://h.example/x"), "invalid"),
        (lambda d: d.update(trust_remote_code=True), "invalid"),
        (lambda d: d.update(engine="plugin"), "invalid"),
        (lambda d: d.update(digest="0" * 64), "invalid"),
    ],
)
def test_unsafe_manifests_are_refused(change, code):
    with pytest.raises(ManifestError) as caught:
        parse_manifest(edit(change))
    assert caught.value.code == f"manifest_{code}"


def test_converter_outputs_must_include_safetensors_and_no_pickle():
    def outputs(names):
        return lambda d: d["conversion"].update(outputs=names)

    for names, code in [
        (["config.json", "weights.npz"], "manifest_pickle"),
        (["config.json", "weights.safetensors", "w.pkl"], "manifest_pickle"),
        (["weights.safetensors", "weights.safetensors"], "manifest_invalid"),
    ]:
        with pytest.raises(ManifestError) as caught:
            parse_manifest(edit(outputs(names), converter=CONVERTER))
        assert caught.value.code == code


@pytest.mark.parametrize("data", [b"", b"[]", b"{", b"\xff", b"null"])
def test_malformed_manifests_are_refused(data):
    with pytest.raises(ManifestError) as caught:
        parse_manifest(data)
    assert caught.value.code == "manifest_invalid"
