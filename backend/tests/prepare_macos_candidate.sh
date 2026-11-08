#!/bin/bash
# Bounded #9 experiment only; not app packaging or native adoption.
set -euo pipefail
umask 077
test "$(uname -s)" = Darwin
test "$(uname -m)" = arm64
rustc --version --verbose | grep -Fx 'host: aarch64-apple-darwin'
root="${RUNNER_TEMP:?}/hagig-issue9-native"
mkdir "$root"
mkdir "$root/evidence" "$root/libraries" "$root/Contents"
mkdir "$root/Contents/Helpers" "$root/Contents/Frameworks"
{
  git rev-parse HEAD
  sw_vers
  uname -m
  rustc --version --verbose
  cargo --version
} > "$root/evidence/environment.txt"
archive="$root/native.tar.bz2"
curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 \
  --max-time 120 --max-filesize 10000000 \
  https://github.com/k2-fsa/sherpa-onnx/releases/download/v2.0.1/sherpa-onnx-v2.0.1-osx-arm64-shared-no-tts-lib.tar.bz2 \
  --output "$archive"
printf '%s  %s\n' ac5594ad237db56ec4a6c4b3fc48700441b33a07bb71c235f35530a52a93f2e3 "$archive" | shasum -a 256 -c -
python3 - "$archive" "$root/libraries" <<'PY'
import pathlib, sys, tarfile
prefix = "sherpa-onnx-v2.0.1-osx-arm64-shared-no-tts-lib/"
names = {"libsherpa-onnx-c-api.dylib", "libsherpa-onnx-cxx-api.dylib", "libonnxruntime.dylib"}
with tarfile.open(sys.argv[1], "r:bz2") as archive:
    members = archive.getmembers()
    files = [m for m in members if m.isfile()]
    assert len(files) == 3 and {m.name for m in files} == {prefix + "lib/" + n for n in names}
    assert all(m.isfile() or (m.isdir() and m.name.rstrip("/") in {prefix.rstrip("/"), prefix + "lib"}) for m in members)
    for member in files:
        target = pathlib.Path(sys.argv[2]) / pathlib.PurePosixPath(member.name).name
        with target.open("xb") as output:
            output.write(archive.extractfile(member).read())
PY
export SHERPA_ONNX_LIB_DIR="$root/libraries"
export CARGO_TARGET_DIR="$root/target"
export RUSTFLAGS='-C link-arg=-Wl,-rpath,@executable_path/../Frameworks'
# Fetch Rust sources explicitly first. Cargo offline does NOT block upstream's
# build-script downloader; both the verified override and OS network deny matter.
cargo fetch --locked --target aarch64-apple-darwin
/usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network*)' \
  cargo build --offline --locked --release --bin hagig --bin hagig-worker
for binary in hagig hagig-worker; do
  cp "$CARGO_TARGET_DIR/release/$binary" "$root/Contents/Helpers/"
done
/usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network*)' \
  cargo build --offline --locked --release --features inference-candidate --bin hagig-inference-worker
cp "$CARGO_TARGET_DIR/release/hagig-inference-worker" "$root/Contents/Helpers/"
# Their existing @rpath IDs and @loader_path entries need no modification/signing.
# C++ API is not linked by this Rust candidate; do not bundle the unused dylib.
cp "$root/libraries/libsherpa-onnx-c-api.dylib" "$root/Contents/Frameworks/"
cp "$root/libraries/libonnxruntime.dylib" "$root/Contents/Frameworks/"
# Remove the acquisition directory AND every build-script library copy. A load
# must use the relocated Frameworks directory, not an absolute build rpath.
rm -rf "$root/libraries" "$root/target"
for binary in "$root/Contents/Helpers/"* "$root/Contents/Frameworks/"*; do
  test "$(lipo -archs "$binary")" = arm64
  otool -L "$binary" >> "$root/evidence/native-layout.txt"
  otool -l "$binary" >> "$root/evidence/native-load-commands.txt"
  shasum -a 256 "$binary" >> "$root/evidence/native-sha256.txt"
done
for binary in hagig hagig-worker; do
  if otool -L "$root/Contents/Helpers/$binary" | grep -E 'sherpa|onnxruntime'; then
    printf 'Trusted binary linked native inference\n' >&2
    exit 1
  fi
done
cat "$root/evidence/native-layout.txt"
printf 'Prepared relocated arm64 candidate; speech inference NOT tested\n'
