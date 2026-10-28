# S1: bounded Linux inference experiment

This is an investigation, not Hagig's CLI, worker, installer, privacy clearance,
or a model-adoption decision. See [findings](FINDINGS.md), [review](REVIEW.md), and
[selected evidence](evidence/). Raw native diagnostics/traces are not published.
The bounded [isolated-worker follow-up](WORKER.md) reuses this exact inference
configuration to test diagnostic containment, failure, cancellation, and recovery.
Started from merged remote `origin/main` commit
`141824784d69fff0efb203dadb1e90145247b61a`, not a parent thread's local branch.

## Reproduce

Run from the repository root on Linux x86-64. Requirements: Rust 1.90.0,
C/C++ linker toolchain, Python 3, curl, bzip2/tar, eSpeak NG 1.51,
FFmpeg 5.1.9, GNU time; strace 6.1 and util-linux unshare for observation.
The source experiment used these tools on Debian 12. This is an environment
inventory, not authorization to install tools: obtain owner approval for tools
outside AGENTS.md's approved set. No tools were installed by the preservation
review. This recipe does not establish a permanent orb/application scaffold.

**Explicit acquisition:** the following downloads about 3.2 GB of candidate assets
from Hugging Face and GitHub. The original NVIDIA archive is needed only to
extract its 10,393-byte scored tokenizer vocabulary; no NeMo/PyTorch installation
or model conversion is needed. Downloaded models, native binaries, generated audio,
and build outputs remain under ignored `.agentic/`, never in Git.

```bash
bash spikes/inference-s1/acquire.sh .agentic/inference
python3 spikes/inference-s1/fixtures.py .agentic/inference/fixtures
export SHERPA_ONNX_LIB_DIR="$PWD/.agentic/inference/native/sherpa-onnx-v2.0.1-linux-x64-shared-no-tts-lib/lib"
export CARGO_TARGET_DIR="$PWD/.agentic/inference/target"
cargo +1.90.0 build --release --locked --manifest-path spikes/inference-s1/Cargo.toml
export LD_LIBRARY_PATH="$SHERPA_ONNX_LIB_DIR"
/usr/bin/time -v -o .agentic/inference/baseline.time \
  "$CARGO_TARGET_DIR/release/hagig-inference-s1" \
  .agentic/inference/assets/model .agentic/inference/fixtures \
  spikes/inference-s1/hotwords.txt > .agentic/inference/baseline.jsonl \
  2> .agentic/inference/baseline.stderr
```

Cargo fetches its pinned Git source and locked crates during build. The upstream
sys build script runs and copies local shared libraries; `SHERPA_ONNX_LIB_DIR`
prevents its default native-library download. The executable itself has no
acquisition path. The initial invocation without `LD_LIBRARY_PATH` failed to load
`libsherpa-onnx-c-api.so`: `readelf -d` showed no executable RPATH/RUNPATH despite
the dependency build script emitting rpath arguments. This recipe sets the loader
path explicitly; it is **not** a relocatable-bundle solution.

The model pins/download URLs are in `acquire.sh`, dependency resolutions in
`Cargo.lock`, and evaluated file hashes in `SHA256SUMS` (paths relative to the
download destination). Verify generated fixtures too:

```bash
(cd .agentic/inference && sha256sum -c ../../spikes/inference-s1/SHA256SUMS)
```

Fixture hash equality depends on the documented speech synthesizer and FFmpeg
versions. `corpus.tsv` columns are ID, class, independently written reference,
and synthesizer text. The invented pronunciation of Hagig is a fixture choice,
not a verified owner pronunciation. Four term clips, four spoken controls
(including the ordinary word "amp"), and digital silence are intentionally small.
Do not use this harness with personal recordings: it deliberately prints and
retains synthetic transcripts. Do not copy its logging policy into Hagig.

## Distinct runtime checks

Repeat the executable under the same environment, separately from timing:

```bash
strace -f -yy -e trace=%network,%file,write,writev,pwrite64 \
  -o .agentic/inference/observed.trace \
  "$CARGO_TARGET_DIR/release/hagig-inference-s1" \
  .agentic/inference/assets/model .agentic/inference/fixtures \
  spikes/inference-s1/hotwords.txt > .agentic/inference/observed.jsonl \
  2> .agentic/inference/observed.stderr
unshare -Urn sh -c 'cat /proc/net/route; curl --noproxy "*" --connect-timeout 2 -sS https://1.1.1.1 >/dev/null'
unshare -Urn strace -f -yy -e trace=%network,%file,write,writev,pwrite64 \
  -o .agentic/inference/blocked.trace \
  "$CARGO_TARGET_DIR/release/hagig-inference-s1" \
  .agentic/inference/assets/model .agentic/inference/fixtures \
  spikes/inference-s1/hotwords.txt > .agentic/inference/blocked.jsonl \
  2> .agentic/inference/blocked.stderr
```

The connectivity probe **should fail** (observed exit 7). A new user/network
namespace has no route/interfaces to external destinations; no production
firewall or host infrastructure was modified. The probe is separate from the
inference trace. `unshare` may be disallowed on another host; report that rather
than treating a proxy variable as network isolation.

Missing-assets checks used `.agentic/inference/missing` (nonexistent). Corrupt
checks used a directory with symlinks to the four valid auxiliary files and
`encoder.int8.onnx` containing `not an ONNX model\n`. Substitute those model paths
in both traced invocations. Each observed failure exited 1. Native corrupt-model
stderr includes its path; do not expose native error strings in the future app.

Raw benchmark tracing above is opt-in synthetic-only scratch under ignored
`.agentic/`; it can contain paths, transcripts, and native errors. Never commit it
or run it on personal inputs. Prefer the worker verifier's RAM-only diagnostic
checks when collecting publishable summaries. Reproduction outputs do not
overwrite the historical evidence in this directory.

The retained JSONL contains every result, including failures of accuracy; first
decode index 0 is not included in warm timing summaries. There are no permanent
mock tests or application framework here.
