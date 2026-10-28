# S1 worker follow-up: Linux diagnostic containment and failure recovery

Status: bounded experimental evidence, **not an adopted inference dependency,
production server, security sandbox, or macOS acceptance**. The original
[S1 findings](FINDINGS.md), assets, dependency pins, and historical evidence remain
in place. No downloads or model/decoder changes were needed for this follow-up.

## Boundary chosen after reading the constitution

`worker_probe.py` is a small Python-standard-library supervisor with no native
inference library loaded. It launches one `isolated-worker` Rust executable per
request. The worker uses the same pinned sherpa-onnx/NeMo TDT configuration as the
original benchmark, now shared through `src/lib.rs`; this is not a new backend.
Python is experiment tooling, **not a proposed replacement for the Rust server**.
Native WAV decoding also stays in the worker. Passing file paths here is a probe
interface, not the proposed server's canonical-PCM transport contract.

**Network-isolation limit:** `worker_probe.py` launches the worker directly; it
does not establish or require a network namespace. Only the explicit
`unshare -Urn` invocations below exercise enforced external-network isolation.
Default/network-available runs are synthetic observation controls, not a compliant
production launch path. Under the current constitution, production must enforce
isolation before native loading and fail closed if unavailable. This preservation
does not implement that launcher or certify macOS `sandbox-exec`.

- Child stdout and stderr are directed to `/dev/null` at spawn, before library
  loading. Native diagnostics are not captured, persisted, redacted, or forwarded
  in the default request path. Panic/loader messages on those descriptors are
  discarded too. This covers descriptors 1/2, not arbitrary dependency logging.
- A dedicated inherited pipe carries one JSON result, capped by the supervisor
  at 64 KiB. Only a structurally valid text reply **and successful process exit**
  permit client stdout. A buffered reply from a crashed worker is discarded.
- Missing assets and failed native construction return stable codes, not raw
  native errors. For example:
  `model_invalid: Verify or explicitly reinstall the candidate assets.`
  No filename, vocabulary, transcript, exception text, or raw configuration is
  included in the tested client request errors. No automatic retry/download.
- After `Popen` returns and assigns the child handle, timeout (30-second
  experimental default), SIGINT, and the opt-in buffered-reply cancellation seam
  discard the result and kill/reap the worker in the tested paths. Each subsequent
  request gets a fresh pipe/process. This is not a guarantee across interruption
  of subprocess construction; see the startup limitation below.
- Core-file limits are set to zero before native execution. This orb's observed
  kernel core pattern is `core`; no system crash handler was reconfigured.
  This is not a claim about macOS CrashReporter, swap, or secure memory erasure.
- Normal request processing writes no audio, transcripts, diagnostics, or cache
  files. User-supplied input/configuration files are read-only. Accepted text on
  CLI stdout is intentional delivery to the caller, not an internal history.

The verifier exposed inherited `SIG_IGN` for SIGINT in this orb's noninteractive
launcher. The CLI explicitly installs Python's SIGINT handler before starting a
request. The final real-SIGINT check now verifies exit 130, empty client stdout,
and disappearance of the child, not just a simulated cancellation return value.

### Cancellation boundary deliberately not expanded

The retained runs establish selected **one-shot process/request cancellation
before client stdout**, plus discard of an already buffered real reply. They do
not establish cleanup at every startup instruction or implement shared-server
admission, request IDs/generations, client disconnect, warm-worker reuse,
cross-client cancellation, app main-actor ordering, or cancellation versus
clipboard/paste. Those require the server/app state machines and are deferred.
Repeated signals during teardown, SIGKILL of the supervisor, hostile workers,
arbitrary inherited descriptors/environment, and malformed CLI invocation are
not a production-hardened contract. Once stdout delivery starts, cancellation
cannot retract it. No server/app/framework was introduced to expand these claims.

### Preserved startup-interruption defect (review finding R5)

A `KeyboardInterrupt` after `Popen` creates the child but before its constructor
returns leaves `request`'s local `child` as `None`. Its cancellation handler can
then return without killing/reaping that child. The original inference verifier's
single real-SIGINT timing does not cover this whole interval. A local controlled
CPython post-spawn/pre-return interruption with a synthetic sleeper reproduced
`cancelled` while the child remained alive; the scratch check explicitly killed
and reaped it afterward. The normal-constructor deadline control did reap it.
See [the sanitized reproduction](evidence/review-startup-interrupt.txt).

This is a deterministic constructor-exception seam, not native inference or a
measurement of real-signal timing/frequency. The exact experimental source is
preserved, not silently repaired. Startup cancellation/resource cleanup remains
unresolved before production use; buffered-result suppression and selected
recovery evidence do not certify all-startup reaping.

## Reproduce from the repository root

Use the already explicitly acquired S1 assets and generated fixtures. Requirements
are the [original recipe](README.md), Python 3.11, Linux `/proc`/memfd, strace and
unshare. There are no new dependencies or source/model pins.

```bash
export SHERPA_ONNX_LIB_DIR="$PWD/.agentic/inference/native/sherpa-onnx-v2.0.1-linux-x64-shared-no-tts-lib/lib"
export CARGO_TARGET_DIR="$PWD/.agentic/inference/target"
export LD_LIBRARY_PATH="$SHERPA_ONNX_LIB_DIR"
export PYTHONDONTWRITEBYTECODE=1
cargo +1.90.0 build --release --offline --locked --manifest-path spikes/inference-s1/Cargo.toml
python3 spikes/inference-s1/worker_probe.py \
  "$CARGO_TARGET_DIR/release/isolated-worker" .agentic/inference/assets/model \
  .agentic/inference/fixtures/control-tests.wav spikes/inference-s1/hotwords.txt
```

Expected successful stdout: `Run the unit tests before changing the parser.`
with newline, empty stderr, exit 0. Invoke via the supervisor; the worker's FD
argument and fault modes are internal experiment interfaces, not a public CLI.

### Explicit synthetic verification, separate from default runtime

```bash
python3 spikes/inference-s1/verify_worker.py \
  "$CARGO_TARGET_DIR/release/isolated-worker" .agentic/inference/assets/model \
  .agentic/inference/fixtures > .agentic/inference/review-worker-observed.jsonl
unshare -Urn sh -c 'cat /proc/net/route; curl --noproxy "*" --connect-timeout 2 -sS https://1.1.1.1 >/dev/null'
unshare -Urn python3 spikes/inference-s1/verify_worker.py \
  "$CARGO_TARGET_DIR/release/isolated-worker" .agentic/inference/assets/model \
  .agentic/inference/fixtures > .agentic/inference/review-worker-blocked.jsonl
```

The connectivity probe should fail (observed curl exit 7). Verification writes
only deliberate synthetic evidence summaries. It creates and deletes synthetic
corrupt-model/vocabulary files in a temporary directory. Positive controls bypass
the supervisor **only in the verifier**, capturing raw native output in RAM to
assert that both canaries were really emitted. Syscall traces are captured in
anonymous Linux memfds with write payload strings omitted, inspected in memory,
and never saved as diagnostic files. Summaries contain no canary values or raw
native diagnostics. Do not run the verifier on personal data. Assertions must be
enabled (do not use Python `-O`). It is not a daily-dictation logging facility.

## Observed results and evidence limits

Both retained verification runs finish with `"verification": "passed"`:
[network available](evidence/worker-observed.jsonl) and
[network blocked](evidence/worker-blocked.jsonl).

| Scenario | Observable client behavior |
| --- | --- |
| Missing model assets | exit 1, `model_missing` with explicit-install guidance, empty stdout |
| Actual corrupt ONNX encoder under synthetic private-path canary | native path leak confirmed in positive control; client exit 1, `model_invalid`, empty stdout, no canary |
| Actual malformed vocabulary native warning | native full-vocabulary leak confirmed in positive control; warning discarded, successful expected transcript only |
| Forced SIGABRT after actual inference and private reply | positive control proves real transcript existed before signal; client exit 1, `worker_failed`, empty stdout; native warning and synthetic stdout marker discarded |
| Cancellation after buffering real reply while worker is held | exit 130, `cancelled`, empty stdout; worker killed/reaped |
| Deadline while a real reply is buffered and worker is held | exit 1, `deadline_exceeded`, empty stdout; worker killed/reaped |
| Real SIGINT during active request | exit 130, `cancelled`, empty stdout; child reaped |
| Subsequent valid request in a fresh worker | exact independent reference transcript, empty stderr, exit 0 |

The same supervisor process additionally runs corrupt → forced crash → buffered
cancel → real successful request; after each call, `waitpid` confirms no child
remains. The supervisor's Linux memory map contains no sherpa-onnx library.
This is recovery of an experimental supervisor, **not proof of server state**.

Evidence levels remain distinct:

1. **Source inspection:** shared configuration preserves S1's pinned native path;
   `worker_probe.py` never loads native inference, discards child descriptors at
   spawn, validates the private reply, checks exit status, and reaps on the tested
   post-construction failure paths (not the R5 startup-interruption path above).
   Upstream `sherpa-onnx/csrc/macros.h:22–52` has platform-dependent logging:
   the normal non-Android/OHOS/WASM macro writes stderr. This is not a review of
   all native/transitive/system logging or build provenance.
2. **Runtime observation:** seven client cases per run are syscall-traced,
   including failures and recovery. All have zero observed network syscalls and
   no writable opens except `/dev/null`. Corrupt-model stderr produces 3 discarded
   writes; vocabulary-warning and crash cases each produce 6; the stdout fault
   seam produces 1 discarded write. The stdout marker is explicitly synthetic,
   not a claim that this native error path emits stdout. All 14 model/WAV hashes
   remain unchanged. No raw positive-control diagnostics are retained.
3. **Blocked networking:** the full verifier repeats inside a new user/network
   namespace with no external route. Outcomes match the network-available run;
   the independent direct-connect probe fails. Offline success alone would not
   establish the zero-attempt observation in step 2.

**Important unresolved behavior:** malformed hotwords can be logged and skipped
by upstream while inference still succeeds. Discarding the warning is containment,
not validation or evidence that bad configuration is rejected. Vocabulary input
validation remains an adoption requirement. **Silence hallucinations are not
fixed:** there is no speech gate here. The shared decoder is unchanged, and S1's
silence negative control remains unresolved. This experiment is cold per request;
it makes no new warm latency or accuracy claim.

## Exact outstanding Mac acceptance work

- Build the pinned Rust/native path for Apple Silicon, on the owner's actual
  M4/48 GB Mac; record OS version. Port this boundary into the minimal Rust
  worker host without adopting the Python experiment as the application server.
- Repeat missing/corrupt/canary/crash/SIGINT/deadline/recovery and buffered-result
  cancellation tests on that native build. Observe file/network attempts and
  outbound-blocked operation separately; inspect unified logging and OS crash
  reports, not only inherited stdout/stderr. Linux core limits do not certify
  macOS crash-report retention or any accelerator caching path.
- Establish in-bundle helper/library resolution, relocation, architecture/local
  signing and installation without developer runtimes or `LD_LIBRARY_PATH`.
- Add and verify speech/no-speech gating without rejecting quiet human speech;
  reject invalid vocabulary safely. Then collect explicit human 10+10 term/control
  fixtures, 20 warm 15–30 s prompts and five-minute timing/peak-memory evidence.
- Separately verify the server/app cancellation and delivery races on Ghostty
  panes/tabs and Chrome/Amp inputs: focus identity, no Enter/focus theft, safe
  fallback, current-device-only clipboard API, plus the second-device clipboard
  observation. This probe has no microphone, Accessibility, UI, or clipboard code.

No Mac execution was performed. Full transitive licensing/privacy/provenance
review from S1 is still open. The experiment establishes a useful Linux process
boundary, not production security or a passed AC3/AC9–AC13 gate as a whole.
