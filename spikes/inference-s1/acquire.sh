#!/usr/bin/env bash
# Explicit candidate acquisition only. Never called by the inference executable.
set -euo pipefail
dest=${1:?Usage: bash acquire.sh DESTINATION (downloads approximately 3.2 GB)}
checksums=$(realpath "$(dirname "$0")/SHA256SUMS")
# Require every named artifact; --ignore-missing would silently omit absent files.
verify() {
  for file in "$@"; do
    entry=$(awk -v path="$file" '$2 == path { print }' "$checksums")
    test -n "$entry"
    (cd "$dest" && printf '%s\n' "$entry" | sha256sum --check --strict)
  done
}
mkdir -p "$dest/assets/model" "$dest/native"
model=https://huggingface.co/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8/resolve/1ab9323565ddb038682214b292f588070a538ce2
for f in encoder.int8.onnx decoder.int8.onnx joiner.int8.onnx tokens.txt; do
  curl -fL --retry 2 "$model/$f" -o "$dest/assets/model/$f"
done
curl -fL --retry 2 https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2/resolve/ae9ad07059c7c739ffaf932226a8fe64ae2620b0/parakeet-tdt-0.6b-v2.nemo -o "$dest/assets/original.nemo"
curl -fL --retry 2 https://github.com/k2-fsa/sherpa-onnx/releases/download/v2.0.1/sherpa-onnx-v2.0.1-linux-x64-shared-no-tts-lib.tar.bz2 -o "$dest/native.tar.bz2"
# Validate downloads before extraction. Hashes record the evaluated artifacts,
# not an independent attestation of the publishers or binary build provenance.
verify native.tar.bz2 assets/original.nemo \
  assets/model/encoder.int8.onnx assets/model/decoder.int8.onnx \
  assets/model/joiner.int8.onnx assets/model/tokens.txt
tar xjf "$dest/native.tar.bz2" --no-same-owner --no-same-permissions -C "$dest/native"
tar xOf "$dest/assets/original.nemo" ./a4715c7f6b2d4c2bb709306073d0c0a4_tokenizer.vocab > "$dest/assets/model/bpe.vocab"
verify assets/model/bpe.vocab \
  native/sherpa-onnx-v2.0.1-linux-x64-shared-no-tts-lib/lib/libonnxruntime.so \
  native/sherpa-onnx-v2.0.1-linux-x64-shared-no-tts-lib/lib/libsherpa-onnx-c-api.so \
  native/sherpa-onnx-v2.0.1-linux-x64-shared-no-tts-lib/lib/libsherpa-onnx-cxx-api.so
