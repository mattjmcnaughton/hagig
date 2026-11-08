#!/bin/bash
# Owner-approved bounded #9 experiment. Not app packaging or adoption clearance.
set -euo pipefail
umask 077
test "$(uname -s)" = Darwin
test "$(uname -m)" = arm64
root="${RUNNER_TEMP:?}/hagig-issue9-native"
helper="$root/Contents/Helpers/hagig-inference-worker"
test -f "$helper"
cleanup() {
  if test -f "$helper.original"; then mv "$helper.original" "$helper"; fi
  if test -d "$root/mutant-source"; then git worktree remove --force "$root/mutant-source"; fi
  rm -rf "$root/data" "$root/mutant-target"
  rm -f "$root/native.tar.bz2"
}
trap cleanup EXIT
export XDG_DATA_HOME="$root/data"
export XDG_CONFIG_HOME="$root/install-config"
# Explicit acquisition outside inference isolation; manifest pins are unchanged.
# No credentials/transfer URLs. The installer verifies every digest, including
# the original tokenizer archive, and deletes the archive before atomic publish.
"$root/Contents/Helpers/hagig" model install parakeet-tdt-0.6b-v2-int8-v1
python3 - "$root" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
manifest = json.loads(pathlib.Path("model-manifest.json").read_text())
models = root / "data/hagig/models"
assert {p.name for p in models.iterdir()} == {manifest["id"], ".install-lock"}
model = models / manifest["id"]
assert {p.name for p in model.iterdir()} == {a["name"] for a in manifest["assets"]}
with (root / "evidence/model-digests.txt").open("w") as report:
    for asset in manifest["assets"]:
        path = model / asset["name"]
        assert path.stat().st_size == asset["bytes"]
        checksum = hashlib.sha256()
        with path.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                checksum.update(chunk)
        assert checksum.hexdigest() == asset["sha256"]
        report.write(f'{asset["name"]} {asset["bytes"]} {checksum.hexdigest()}\n')
print("EXPLICIT NETWORK INSTALL PASS: five pinned assets; no archive/stage retained")
PY
"$root/Contents/Helpers/hagig" model install parakeet-tdt-0.6b-v2-int8-v1
shasum -a 256 tests/native_speech.py tests/fixtures/speech.wav > "$root/evidence/speech-artifact.txt"
python3 tests/native_speech.py --root "$root" 2>&1 | tee "$root/evidence/speech-required.txt"
python3 tests/native_speech.py --root "$root" --mode disabled 2>&1 | tee "$root/evidence/speech-disabled.txt"

# Original base lacks this CLI. Falsify sample dependence by changing only the
# native helper in a disposable source/build tree, never the checked-out source.
git worktree add --detach "$root/mutant-source" HEAD
python3 - "$root/mutant-source/backend/src/bin/hagig-inference-worker.rs" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
source = path.read_text()
original = "stream.accept_waveform(16_000, &samples);"
assert source.count(original) == 1
path.write_text(source.replace(original, "stream.accept_waveform(16_000, &vec![0.0; samples.len()]);"))
PY
git -C "$root/mutant-source" diff -- backend/src/bin/hagig-inference-worker.rs > "$root/evidence/zero-pcm-mutation.diff"
export SHERPA_ONNX_LIB_DIR="$root/Contents/Frameworks"
export CARGO_TARGET_DIR="$root/mutant-target"
export RUSTFLAGS='-C link-arg=-Wl,-rpath,@executable_path/../Frameworks'
/usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network*)' \
  cargo build --manifest-path "$root/mutant-source/backend/Cargo.toml" \
    --offline --locked --release --features inference-candidate --bin hagig-inference-worker
mv "$helper" "$helper.original"
cp "$CARGO_TARGET_DIR/release/hagig-inference-worker" "$helper"
git worktree remove --force "$root/mutant-source"
rm -rf "$CARGO_TARGET_DIR"
shasum -a 256 "$helper" "$helper.original" > "$root/evidence/speech-worker-digests.txt"
control_status=0
python3 tests/native_speech.py --root "$root" > "$root/evidence/speech-zero-pcm.txt" 2>&1 || control_status=$?
# Compile/loader/setup/cleanup failures are NOT valid counterfactuals.
test "$control_status" -eq 42
grep '^SUPPLIED_SPEECH_MISMATCH_CLEANUP_PASS:' "$root/evidence/speech-zero-pcm.txt"
mv "$helper.original" "$helper"
python3 tests/native_speech.py --root "$root" 2>&1 | tee "$root/evidence/speech-restored.txt"
shasum -a 256 tests/native_speech.py tests/fixtures/speech.wav > "$root/evidence/speech-artifact-restored.txt"
cmp "$root/evidence/speech-artifact.txt" "$root/evidence/speech-artifact-restored.txt"
printf 'SAMPLE-DEPENDENCE MUTATION PASS; lifecycle checks executed, not separately falsified\n'
