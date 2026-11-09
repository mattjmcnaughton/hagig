# Pinned inference stack: bounded security audit

Date: 2026-11-02. Issue [#25](https://github.com/mattjmcnaughton/hagig/issues/25).
**Checkpoint, not adoption clearance or completed issue acceptance.** Source review
finds actionable WAV memory-safety defects and a safe-Rust concurrency hazard.
Their presence in the evaluated prebuilt native library is not established by
the source pin. No native exploit, sanitizer run, formal acceptance proof, or
Mac test was executed in this pass. Finite review cannot establish vulnerability
absence. Unresolved material findings require an explicit adoption decision.

Privacy verdict: **indeterminate for the whole shipped stack**. This security
pass is not a claim of no outbound channels, no writes, or successful operation
with networking blocked. Keep those three evidence tracks separate; #6 owns
runtime privacy and asset/license/provenance investigation. See [WORKER.md](WORKER.md)
and [FINDINGS.md](FINDINGS.md) for earlier, bounded experiments, not new results.
License/redistribution permission is not a security or provenance finding.

## Revisions, evidence boundary and inventory

Hagig base: `b34129a9f92713442855e94c5c7b34497b7e2ab6`. Candidate inspected by
`git show`: PR18 `095ed8102ebef43b1a0e56a2af45829b8c85c5a5` (abbreviated **H**
below). Its S1 Cargo manifest and lock equal the base versions. H is not the
final #9 dependency set or #23 packaged artifact.

**S** means the recovered k2-fsa/sherpa-onnx checkout at
`af2d8d81dbfa61c4cea4c568da78f3982edca005`. Its Git status reports a deleted
`rust-api-examples/.cargo/config.toml` and untracked `.cargo-ok`; no tracked
modification to cited library/build files was reported. Nothing in that cache
was changed. Searches used explicit Rust, C API, C++ and cmake paths, without
following symlinks. In particular the two absolute `/Users/fangjun` Go example
links were not followed. Examples, unrelated inference families, servers, mobile,
GPU implementations and complete transitive source trees were not audited.

**O** is a *comparison source*, Microsoft ORT tag v1.28.2 resolving through the
public GitHub ref API to `33ca9628233dc8f002435e868d4c2e9f82766ca1`.
Only `inference_session.cc`, `inference_session_utils.h` and selected external-data
sections of `tensorprotoutils.cc` were inspected. This is not an ORT-wide audit or
evidence that the third-party prebuilt ORT was built from O.

| Component | Exact selection / features | Evidence and limitation |
| --- | --- | --- |
| Rust application | `hagig-inference-s1` 0.0.0, edition 2021; two direct dependencies: sherpa-onnx, serde_json | [Cargo.toml](Cargo.toml); H `src/lib.rs:7–36`, `src/bin/isolated-worker.rs:6–19` |
| Rust wrapper / raw ABI | sherpa-onnx and sherpa-onnx-sys 2.0.1, Git S; `default-features=false`, `shared` only | S `sherpa-onnx/rust/{sherpa-onnx,sherpa-onnx-sys}/Cargo.toml`; no bindgen run, hand-maintained `repr(C)` declarations |
| Rust runtime | serde/serde_core 1.0.229, serde_json 1.0.154, itoa 1.0.18, memchr 2.8.3, zmij 1.0.23 | [Cargo.lock](Cargo.lock), authoritative exact roster/checksums; serde derive enabled by wrapper |
| Rust compile-time | serde_derive 1.0.229, proc-macro2 1.0.107, quote 1.0.47, syn 3.0.9, unicode-ident 1.0.27 | Same lock; proc macros are build-time code execution, not worker runtime parsers |
| sys build dependencies | bzip2 0.4.4, tar 0.4.46, ureq 2.12.1, zip 9.1.2; defaults retained | ureq: TLS/gzip + explicit proxy-from-env. ZIP defaults: aes-crypto, bzip2, deflate64, deflate, lzma, ppmd, time, zstd, xz. Compiled does not mean used by Linux extraction |
| Build transitives of particular security relevance | bzip2-sys 0.1.13+1.0.8, zstd-sys 2.1.2+zstd.1.5.7, rustls 0.23.46, ring 0.17.14, rustls-webpki 0.103.16, rustls-pki-types 1.15.1, flate2 1.1.10 | Lock contains 144 package entries including application and target-specific entries; this is not 144 runtime dependencies. No Cargo feature resolution/build executed; feature statements are manifest-derived, not a final target build report |
| Native evaluated candidate | `sherpa-onnx-v2.0.1-linux-x64-shared-no-tts-lib.tar.bz2`; C API, C++ API and ORT .so files | [acquire.sh](acquire.sh), [SHA256SUMS](SHA256SUMS). Wrapper calls C API; C++ API is an acquired extra, not a direct Rust call target |
| Native source dependency declarations | ORT 1.28.2; kaldi-native-fbank 1.22.4 / kissfft; simple-sentencepiece 0.7 (`ssentencepiece`); utf8proc 2.12.0; kaldi-decoder 0.3.0; OpenFST fork 1.8.5-2026-07-09 | S `cmake/{onnxruntime-linux-x86_64,kaldi-native-fbank,simple-sentencepiece,utf8proc,kaldi-decoder,openfst}.cmake` carry URLs + SHA256; Rust sys `build.rs:16–28` lists static link names. Not a verified prebuilt SBOM; kissfft exact revision and nested dependencies remain gaps |
| Execution | CPU explicitly, 2 threads; NeMo transducer, BPE, modified beam search, max_active_paths 4, hotwords score 1.5, debug false | H `src/lib.rs:26–35`. No configured LM, FST/FAR rules, homophone replacer or custom op library. No claimed CUDA/CoreML/Neural Engine use; available/compiled providers in binary not enumerated here |
| Model inputs | Parakeet TDT 0.6B v2 int8 encoder/decoder/joiner + tokens at HF conversion revision `1ab9323565ddb038682214b292f588070a538ce2`; scored `bpe.vocab` from NVIDIA NeMo revision `ae9ad07059c7c739ffaf932226a8fe64ae2620b0` | acquire script lines 17–41, hashes in SHA256SUMS. ONNX is a format, not a separate selected inference engine. NeMo archive is installer input only; no Python NeMo/PyTorch runtime in this path. #6 owns asset provenance/licenses |

Read-only ELF inspection of the three recovered .so files found `$ORIGIN` RPATH.
The C API needs `libonnxruntime.so`; C++ API needs both C API and ORT. Dependencies
also include libc, libstdc++, libgcc_s, libm, libpthread, libdl, and ELF loader;
ORT additionally lists librt. ORT contains the string `1.28.2`; this is an identity
hint, not attestation. No `ldd` or library loading was used. Hash validation is
byte identity against recorded expectations, not publisher identity, compiler
flags, ABI equality, reproducibility or source/binary correspondence.

## Threat model

Private local dictation can contain secrets. Protect confidentiality of audio,
transcripts, vocabulary and paths; integrity of app/server state and installed
models; and availability of the host, not only of a worker. Attackers can supply
malformed WAV/PCM or poisoned vocabulary/assets/archive inputs through a file or
distribution channel. Worker replies become untrusted after native compromise.
There is no remote listening-service attacker in this selected S1 path. A process
already controlling the same user's files/environment is outside the alpha's
authentication promise, but compromised archives and accidental inheritance are
still meaningful defense-in-depth risks. Do not run acquisition/build as root.

Trust crossings: explicit acquisition -> extraction/staging -> installed files ->
native loader -> Rust/C ABI -> C++ WAV/features/tokenizer -> ORT graph/optimizers/
CPU kernels -> JSON C string -> Rust -> bounded private reply pipe -> supervisor.
Required-mode network isolation must precede *dynamic library loading*, not just
`main()`/model creation; the loader runs before Rust entry. Disabled mode is an
explicit opt-out from OS network blocking, not from process separation, offline
operation, diagnostic containment or the no-upload contract. Neither mode's
network policy alone prevents filesystem reads/writes or memory-corruption RCE.

## Reviewed-surface matrix

Source locations below are against S or H, never an implied prebuilt source map.

| Input / boundary | Inspected source and assessment | Remaining check / containment |
| --- | --- | --- |
| WAV header/chunks/data | S `csrc/wave-reader.cc:23–53,68–337,346–377` accepts PCM8/16/32 and float32, multiple channels (returns first), fmt16/18; see F1/F2 | No safe five-minute/file-byte cap, complete-frame validation or checked header products; run negative cases only in disposable child |
| PCM pointer/length/rate | S Rust `src/offline_asr.rs:748–758` narrows usize to i32; C API `c-api.cc:765–770`; C++ `offline-stream.cc:136–194,234–263` | `try_from` length, positive supported rate, finite samples, cumulative 4,800,000-sample cap at canonical 16 kHz, checked feature products before native call. S1 does not enforce these product limits |
| Strings/config C ABI | S Rust `utils.rs:58–66`, `offline_asr.rs:598–619,688–711`; C API `c-api.cc:451–480,703–725` copies path strings into native config, validates config, catches recognizer construction exceptions | CString backing allocations survive conversion/call; vector moves do not move CString buffers. Interior NUL unwrap panics rather than controlled error. No general catch at every extern-C boundary; avoid assuming native exceptions are Rust Results |
| Ownership/results | S Rust `offline_asr.rs:731–737,761–805`, `wave.rs:54–79`; C API `c-api.cc:971–985,2179–2233` | Drop/free and JSON copy/free pair inspected. CStr/raw slice trust native termination, count and allocation. No observed dangling config-string bug; no claim all stream/recognizer cross-use or ABI offsets are safe |
| Concurrency/lifetimes | S Rust `offline_asr.rs:680–686,714–727,740–779`; C++ `offline-stream.cc:136–194,276–295,357–376` | See F3. C++ stream owns state/context graph; absence of Rust lifetime tie alone is not proof of recognizer-drop UAF. Foreign-recognizer streams and batch use remain unverified |
| Vocabulary/token/BPE | H `src/vocabulary.rs:3–28` caps 256 terms, 128 UTF-8 bytes/term, rejects controls, slash, colon, malformed spaces; H worker reads whole file first. S `offline-recognizer-transducer-impl.h:86–115,163–197`, `utils.cc:104–205`, `symbol-table.cc:109–178` | Syntax limits do not establish BPE representability. Native tokenizer input/score/id consistency, duplicate/missing IDs, huge lines and empty-encoding paths not exhaustively validated; bound read before allocation, verify exact installed assets. #6 owns representability/privacy follow-up |
| Model metadata/shapes | S `offline-transducer-nemo-model.cc:34–52,173–226` constructs 3 ORT sessions and reads integer metadata (including `vocab_size_ += 1`) | Treat graph/metadata as hostile, not passive weights. Need shape/dimension/operator inventory and bounds review with final verified native source; malformed metadata may throw/exit or drive allocations. No model RCE established |
| ORT external initializers | O `tensorprotoutils.cc:201–249,418–557` contains file-length/SafeInt checks, canonical containment and symlinked-model fallback; O `inference_session.cc:1194–1229` delegates path model loading | Do not misreport all `../` handling as an unchecked traversal. Immutable private model directory still needed against replacement/races. Complete loader/initializer call graph, memory-address tags and all kernels not reviewed; source checks not verified in binary |
| Providers/code loading | S `session.cc:106–141,209–310` accepts optional `provider:config`; can enable profiling and forward `SessionConfig.*`. H fixes provider to plain `cpu` | No direct RegisterCustomOpsLibrary call in inspected candidate path. O `inference_session.cc:1197–1203` has conditional `ENABLE_LANGUAGE_INTEROP_OPS` loading; build-flag evidence needed, not assumption that ONNX cannot trigger other code paths. No plugin architecture recommended |
| Build/download/cache | S sys `build.rs:110–126,141–240,752–851`: LIB_DIR override, cache reuse, proxy-aware GitHub fetch, archive unpack, copying and `.part` rename | F4; build-time traffic is not inference traffic. ZIP branch is xcframework/iOS, not Linux/macOS tar branch. Atomic rename alone does not enforce trustworthy content/root/symlink policy |
| Explicit shell installer | Hagig `acquire.sh:6–41` checks all requested hashes before extraction; GNU tar flags drop owner/permissions; extracts one named NeMo member to stdout | Not run. No assertion of arbitrary archive traversal exploit: GNU tar and Rust tar have their own protections. Add entry/type/size allowlisting, private fresh staging, no symlink destinations, atomic publish before adapting into installer |
| Worker launch/replies | H `worker_probe.py:28–86`, `src/bin/isolated-worker.rs:22–53`: core limit zero, DEVNULL diagnostics, pass_fds only reply pipe, 64 KiB reply cap, successful exit required, kill/reap on terminal paths | Popen does not pass `env`, so environment inherited. This is an experimental supervisor, no in-function required/disabled isolation selector. No filesystem sandbox or resource memory cap; do not promote it as production containment. Final #9/#23 launch and both modes need recheck |

## Findings and smallest remediation

Severity is impact *if reachable in reviewed source*, not a CVSS certificate or
claim of exploitable shipped binaries. F1/F2 are confirmed source-level bounds
defects by inspection, not confirmed packaged exploits. F3 is an API safety hazard
outside the candidate's sequential call pattern. F4 is a build trust-boundary gap.

### F1 — HIGH: malformed WAV data size exceeds allocated 32-bit sample buffer

S `sherpa-onnx/csrc/wave-reader.cc:281–289,305–313` allocates
`vector<int32_t/float>(subchunk2_size / 4)` and reads `subchunk2_size` bytes.
A positive size not divisible by four reads up to three bytes past the vector's
logical allocation. Example: 5 declared/available bytes allocate 4 then read 5.
Read-success testing occurs **after** the write. Reachable via safe Rust
`Wave::read` -> `SherpaOnnxReadWave` -> `ReadWaveImpl`, including H worker line 11;
no model tampering or giant input necessary. Native heap corruption can kill or
potentially compromise the worker; code execution has not been demonstrated.

Minimum source fix: reject negative/non-frame-aligned data sizes and short data
before allocation/read; compute checked byte/sample counts, read exactly the
validated allocation length. A worker process limits crash propagation but is
not a repair for memory corruption. Until the native artifact's fix is verified,
do not expose this WAV reader to untrusted files. A separately reviewed bounded
decoder to canonical PCM can remove this parser from the final inference path;
no new decoder/dependency is selected by this report.

### F2 — HIGH: partial multi-channel frame causes out-of-bounds deinterleave

S `wave-reader.cc:241–250,265–278,295–303,319–327` resizes each output to
`samples.size()/num_channels`, then advances the input by channel count without
requiring exact division. Three PCM16 samples with two channels allocate one
output frame, then the second iteration writes frame index 1 and reads sample
index 3 (past length 3). The mono-facing API still parses all channels first
(`wave-reader.cc:363–377`), so returning only channel zero does not remove this
reachability. Impact and binary uncertainty are as for F1.

Minimum source fix: require `data_size % block_align == 0`, validate consistent
nonzero block_align, channel and sample sizes with checked arithmetic, and loop
over validated frame count. The same validation prevents this across all four
sample-format branches. Also reject impossible/negative rate and chunk lengths
before signed header products (`wave-reader.cc:169–183`) or seeks (`28–37`).

### F3 — MEDIUM (latent): safe shared Rust API permits native data races

S Rust `offline_asr.rs:744–779` declares `OfflineStream: Sync` and exposes
`accept_waveform(&self)` / `set_option(&self)`; native stream holds mutable
feature extractor and unordered_map without a lock at the inspected methods.
Two safe Rust scoped threads sharing one stream can call `accept_waveform` or
`set_option` concurrently. Concurrent mutation is not made safe by the comment
"thread-safe for single-object usage." Result reads can also race with writes.
H uses one thread sequentially, so this is not a demonstrated malicious-input
exploit in H. Review recognizer Sync/batch methods too rather than fixing only a
single call. No race detector was run.

Minimum application containment: keep all recognizer/stream operations on one
worker thread, no concurrent teardown; kill/reap worker for cancellation. Minimum
binding repair: remove unjustified Sync and/or serialize native object access,
require exclusive access for mutation, then validate remaining Send/Sync contracts.
Do not introduce a DI/engine abstraction to contain this.

### F4 — MEDIUM: build selects native code without integrity enforcement

S sys `build.rs:115–126,164–166,191–215,223–240` trusts an existing LIB_DIR or
extracted cache and otherwise downloads a version-tagged release without a
checksum/signature comparison before unpack/link. Archive-dir override is also
unverified. This is build-time arbitrary-code trust, not an automatic runtime
download. Local recipe's explicit acquisition+SHA256 and LIB_DIR bypass the
default fetch, but do not make upstream build.rs independently verified.
`build.rs:788–813` canonicalizes library sources and copies all names matching
`.so`/`.dylib`, with no manifest allowlist; symlink source targets can be outside
the supplied directory. Destination symlink/race protection and archive expansion
caps are not enforced here. These are conditional surfaces, not tested traversal
or privilege-escalation exploits; malicious same-user cache modification alone
does not break the alpha's stated authentication boundary.

Minimum build policy: private clean staging/cache, verified explicitly supplied
allowlisted native artifacts, no ambient writable loader directories, non-root
build, fail on missing/corrupt inputs rather than fetch. Packaging must seal the
library set and relocatable loader paths. #6 must supply provenance conclusions;
do not assert that TLS/checksum or matching version text closes correspondence.

## Bounded checks and proposed negative-case protocol

Executed here: read-only `git show`, manifest/lock comparison (identical H/base;
144 package entries), scoped source reads/searches, ELF `readelf -d`, targeted
version-string inspection, and Python standard-library arithmetic only. Arithmetic
confirmed 5-byte/32-bit allocation = 4 bytes and stereo-three-sample frame capacity
= 1 versus last frame index = 1. **This is not a native reproduction**, sanitizer
result or acceptance proof. No build.rs, acquire.sh, native inference, fixtures,
network probe, scanner, new tool, fuzzing or exploit was run.

Owner capture proposal (not approved/executed):

1. In a private disposable non-root directory/child, synthesize RIFF/WAVE fmt16
   headers with matching byte_rate/block_align and bounded payloads. F1: mono
   float32 and PCM32, data sizes 4 (control), 5/6/7 (negative), 8 (control).
   F2: stereo PCM16, sizes 4/8 (control), 6 (negative); extend PCM8/32/float32
   partial-frame cases. Include negative/oversize data, zero/negative/overflowing
   rate/channel products, odd ancillary chunks, truncated headers/data and empty
   audio. Never allocate declared huge sizes; enforce child memory/time limits.
2. Invoke actual Wave/C API in the isolated worker, not the parent; disable core
   files and discard native diagnostics from public outputs. For source-level
   memory access evidence request a specifically approved sanitizer build/toolchain
   of the corresponding native source; no such build has been authorized here.
   Prebuilt exit-0/crash alone neither proves nor disproves a sub-allocation OOB.
3. Repeat identical cases on unchanged and repaired source/artifacts. Require safe
   rejection of malformed inputs, supported controls unchanged, no delivered
   result after failure/cancellation, parent survival and next-request recovery.
   F3 needs separate approved race validation or an API compile-fail contract;
   do not concurrently access native state in the application as an experiment.
4. Repeat on exact #23 package with final #9 features, required and explicitly
   disabled isolation; separately validate required-mode setup failure/no target
   execution/no fallback. Hosted Mac and physical-Mac/human evidence remain
   distinct. #6 owns network/write observation and blocked-network protocols.

## Published advisory triage

Public primary records read on 2026-11-02; no lockfile/source was submitted to
a scanner service. This is a targeted triage, **not** a complete RustSec/OSV/MSRC
scan, all-native CVE inventory, or proof of current database completeness.

| Record | Version / feature applicability and disposition |
| --- | --- |
| [RUSTSEC-2026-0067](https://rustsec.org/advisories/RUSTSEC-2026-0067.html) / CVE-2026-33056; [0068](https://rustsec.org/advisories/RUSTSEC-2026-0068.html) / CVE-2026-33055 | tar symlink chmod / PAX size discrepancy; patched >=0.4.45. Locked 0.4.46 is outside affected range. Extraction is reachable at build time, not inference; no waiver or clean-archive guarantee implied |
| [RUSTSEC-2025-0168](https://rustsec.org/advisories/RUSTSEC-2025-0168.html) / CVE-2025-29787 | zip extraction canonicalization; affected >=1.3.0,<2.3.0, fixed >=2.3.0; locked 9.1.2 outside range |
| [RUSTSEC-2026-0367](https://rustsec.org/advisories/RUSTSEC-2026-0367.html), [0368](https://rustsec.org/advisories/RUSTSEC-2026-0368.html), [0369](https://rustsec.org/advisories/RUSTSEC-2026-0369.html) | ZIP privileged modes, outside-root symlink targets, symlink chmod respectively; primary records say patched >=9.0.0, lock 9.1.2 outside affected range. ZIP extract call exists for iOS xcframework, not evaluated Linux/macOS tar branch. Advisory headline severity is not this candidate's severity |
| [RUSTSEC-2026-0346](https://rustsec.org/advisories/RUSTSEC-2026-0346.html), [0347](https://rustsec.org/advisories/RUSTSEC-2026-0347.html), [0348](https://rustsec.org/advisories/RUSTSEC-2026-0348.html), [0349](https://rustsec.org/advisories/RUSTSEC-2026-0349.html) | rustls session Debug secrets / ECH rejection / Brotli allocation / key-share prediction; patched >=0.23.46 and locked exactly 0.23.46. Build-time ureq HTTPS only here, not inference. Brotli is non-default and absent from this lock; no custom session-store or ECH use established |
| [RUSTSEC-2026-0285](https://rustsec.org/advisories/RUSTSEC-2026-0285.html) | rustls TLS1.3 encryption-level boundary acceptance, fixed >=0.23.45; 0.23.46 outside affected range |
| [ORT 1.24.3 security fixes](https://github.com/microsoft/onnxruntime/releases/tag/v1.24.3) | GatherCopyData integer truncation/OOB, RoiAlign batch-index OOB, malicious LoRA OOB, Resize OOB fixed in release notes. CPU graph parsing/kernels make several classes relevant; no LoRA API configured in H, TRT custom-op double-free path not selected by CPU. Declared/hinted 1.28.2 is later, but vendor fork/backport ancestry and binary correspondence unverified: **packaged applicability unresolved**, not cleared solely by numeric ordering. Need source/build mapping and selected graph operators |
| [GHSA-538c-55jv-c5g9](https://github.com/onnx/onnx/security/advisories/GHSA-538c-55jv-c5g9) / CVE-2026-34445 | Python onnx ExternalDataInfo setattr/object corruption <=1.20.1, fixed 1.21.0. Not the native Rust/C++ ORT runtime path: Python onnx not selected. Do not transpose this package's version range onto ORT |

[ORT security page](https://github.com/microsoft/onnxruntime/security) reports no
published GitHub advisories and directs reports to MSRC; that is not evidence of
no vulnerabilities (release notes explicitly contain security fixes). ureq package
RustSec page returned 404; that is an incomplete lookup, not a clean result.
Other Rust/native transitives, OS C/C++ runtime versions and newly published
advisories remain untriaged. Re-run advisory analysis on final exact inventory.

## Finding-driven configuration and maximum-security baseline

Existing knobs, not invented settings:

| Knob / source | Default -> restrictive candidate posture | Boundary |
| --- | --- | --- |
| Cargo `default-features`, `shared` (H manifest) | upstream static -> explicit shared only | Link choice, not a memory-safety mitigation |
| `SHERPA_ONNX_LIB_DIR` (S sys build.rs:115) | absent -> verified private native directory | Avoids default download; does not verify directory content itself |
| `SHERPA_ONNX_ARCHIVE_DIR` (build.rs:193) | absent -> not used when LIB_DIR supplied | Local archive is still unverified unless separately checked |
| `provider` / `debug` (H lib.rs:30–32) | wrapper defaults -> fixed `cpu`, false | Do not expose arbitrary `cpu:config` or SessionConfig.* to untrusted clients; debug false is not a universal diagnostics off-switch |
| `num_threads`, `max_active_paths`, `hotwords_score` (H lib.rs:31,34–35) | explicit 2 / 4 / 1.5 | Bounded candidate configuration, not total CPU/RAM/time limits |
| `ORT_LOAD_CONFIG_FROM_MODEL` (O inference_session_utils.h:28; inference_session.cc:368–433) | unset -> keep unset or 0 in allowlisted child environment | 1 substitutes model-provided JSON session options. Source-comparison fact, not verified packaged behavior |
| `ProfilingFilePrefix`, `SessionConfig.*` (S session.cc:251–297) | no provider config -> leave absent | Profiling enables file writes; arbitrary session forwarding enlarges loading/options surface |
| `RLIMIT_CORE`, reply cap, timeout (H worker_probe.py:28–55,95) | 0 / 65536 bytes / 30 seconds | Experimental process controls; not a filesystem sandbox or full host resource budget |

Apply together: immutable verified model/native files in private directories;
single-thread native object ownership; reject malformed/oversized input before
native parsing; no untrusted Wave::read pending F1/F2 resolution; sanitized
environment/descriptor allowlist and private IPC; bundle-relative sealed library
paths without developer LD_LIBRARY_PATH/DYLD_* requirements; establish required
network policy before exec/load, with explicit disabled mode separately reported.
These are recommendations requiring implementation/verification, not controls this
document installs. No universal "disable every native side effect" switch was
found. Filesystem isolation, memory limits, archive staging validation, loader
hardening and ABI/source correspondence cannot be obtained by flipping debug off.

## Source references and remaining adoption gates

Pinned navigable roots (append paths/line ranges from tables):

- [S Rust wrapper](https://github.com/k2-fsa/sherpa-onnx/blob/af2d8d81dbfa61c4cea4c568da78f3982edca005/sherpa-onnx/rust/sherpa-onnx/src/offline_asr.rs#L680-L805)
- [S WAV parser](https://github.com/k2-fsa/sherpa-onnx/blob/af2d8d81dbfa61c4cea4c568da78f3982edca005/sherpa-onnx/csrc/wave-reader.cc#L228-L337)
- [S native stream](https://github.com/k2-fsa/sherpa-onnx/blob/af2d8d81dbfa61c4cea4c568da78f3982edca005/sherpa-onnx/csrc/offline-stream.cc#L136-L194)
- [S C ABI](https://github.com/k2-fsa/sherpa-onnx/blob/af2d8d81dbfa61c4cea4c568da78f3982edca005/sherpa-onnx/c-api/c-api.cc#L703-L804)
- [S sys build](https://github.com/k2-fsa/sherpa-onnx/blob/af2d8d81dbfa61c4cea4c568da78f3982edca005/sherpa-onnx/rust/sherpa-onnx-sys/build.rs#L110-L240)
- [H worker](https://github.com/mattjmcnaughton/hagig/blob/095ed8102ebef43b1a0e56a2af45829b8c85c5a5/spikes/inference-s1/src/bin/isolated-worker.rs#L6-L19)
- [H supervisor](https://github.com/mattjmcnaughton/hagig/blob/095ed8102ebef43b1a0e56a2af45829b8c85c5a5/spikes/inference-s1/worker_probe.py#L28-L86)
- [O model/session loading](https://github.com/microsoft/onnxruntime/blob/33ca9628233dc8f002435e868d4c2e9f82766ca1/onnxruntime/core/session/inference_session.cc#L1194-L1229)
- [O external-data validation](https://github.com/microsoft/onnxruntime/blob/33ca9628233dc8f002435e868d4c2e9f82766ca1/onnxruntime/core/framework/tensorprotoutils.cc#L418-L557)

Review checkpoint and remaining issue acceptance, in order:

1. Independent complete-file documentation and source-factual reviews completed
   on 2026-11-02. No factual blocker was found; the missing root documentation
   gate is a retained coverage limitation. This does not establish native
   reproduction, prebuilt applicability or completed issue acceptance.
2. Obtain #6 binary/asset identity, provenance and license conclusions; request
   matching native source/build recipes/flags (including ORT interop/custom-op/
   provider configuration and nested native dependencies). Public O source is
   available; the blocker is trustworthy correspondence and finite remaining
   review, not permission to download more binaries/models. No source matched
   binary claim can be made from S, O, release names or strings alone.
3. Owner approve concrete capture plan and any specific sanitizer/race-tool build
   acquisition before native repro. Until then F1/F2 source defects are actionable
   but isolated-native-repro acceptance is **UNPROVEN**. Propose patched source or
   parser avoidance; keep unchanged-case evidence private and synthetic only.
4. Finish ORT graph/optimizer/kernel, tokenizer implementation and transitive
   advisory review against matching source; review every final ABI struct offset,
   provider/library search path, archive entry policy and worker environment/FD
   boundary. The full Rust lock is recorded, not exhaustively security-reviewed.
5. Recheck actual #9 integration and #23 relocated package in both explicit
   isolation modes; required mode must fail closed before native load. Mac native
   CI, owner physical-Mac/human audio and #10 acceptance remain separate gates.
   Do not close #25 or adopt the candidate based on this documentation checkpoint.

## Final backend reconciliation — 2026-11-09

This section applies the findings above to the merged backend on main
`369039530b6135ca760a45164d490532933bf8e5`. Its `backend/src` and `backend/tests`
are byte-identical to PR31 head `db18603`, which was exercised on hosted Apple
Silicon. It is a source-level reconciliation plus a refreshed advisory triage.
It is **not** a native reproduction, a source/binary correspondence check, or
adoption clearance. Earlier sections remain the historical record for H.

### Findings against the final path

| Finding | Final backend state | Still open |
| --- | --- | --- |
| F1/F2 native WAV reader | **Avoided, not repaired.** `backend/src/audio.rs` decodes WAV in safe Rust: a 300 s/file-byte cap before allocation, complete-frame alignment and finite samples. The worker receives only canonical PCM. `worker_protocol::read_request` requires 4-byte alignment, at most 19,200,000 bytes and every sample in [-1,1] (NaN rejected) before `accept_waveform`. No `Wave::read` call exists | Native reader defects in the prebuilt library remain unreproduced and unrepaired; never expose it to untrusted files |
| F3 shared-stream race | **Contained by ownership.** `hagig-inference-worker` is single-threaded. It creates one stream per request and calls `accept_waveform`/`decode`/`get_result` sequentially. Cancellation kills and reaps the process rather than tearing down concurrently | Binding `Sync` hazard unrepaired upstream |
| F4 native build integrity | **Contained in the documented recipe.** `backend/tests/prepare_macos_candidate.sh` verifies the archive SHA256 (`ac5594ad…f2e3`) and extracts only three allowlisted regular dylibs. It passes them via absolute `SHERPA_ONNX_LIB_DIR`, runs `cargo fetch --locked` first, then builds under `sandbox-exec (deny network*)`. The build-script downloader therefore cannot fetch. The trusted CLI/bootstrap are checked not to link sherpa/ORT | Only the archive's bytes are pinned, not where they came from or whether they match the sherpa-onnx source (see [LICENSES.md](LICENSES.md) on its universal2-thinned ORT input). Upstream `build.rs` remains unverified when used without the recipe |
| Config/provider surface | Fixed `provider=cpu`, `debug=false`, two threads, `max_active_paths=4`. Worker exec uses `env_clear()` and `cwd=/` (so `ORT_LOAD_CONFIG_FROM_MODEL` is absent), and no `SessionConfig.*`/profiling is forwarded. Vocabulary syntax rejects control characters (including NUL), `/`, `:` and over-length terms. A pinned-table scalar check runs before native construction | Interior-NUL panics are unreachable via validated config but not via other callers; model paths are re-opened by native code after hash validation (TOCTOU within the user's private model directory) |
| Model assets | Runtime hash-validates all five manifest assets inside the isolated worker before recognizer creation. The installer never unpacks the `.nemo`: it reads one literal tar member bounded by size and SHA256 | ONNX graph/metadata, ORT kernel and tokenizer native parsing not audited |

### Advisory triage, final `backend/Cargo.lock` (154 entries)

Sources (read 2026-11-09, no scanner run):
- RustSec advisory-db at `7a40350e1b8ba5b656d909f88222a8059a83d88d` (2026-11-08).
- The OSV crates.io bulk export (last modified 2026-11-08, 3,055 records), matched by version range against every locked name.
- The GitHub advisory API per crate (reviewed, unreviewed and malware).

All lookups succeeded. The features cited below were checked with `cargo tree -e features`.

| Record | Locked | Affected? | Reachability |
| --- | --- | --- | --- |
| [RUSTSEC-2026-0386](https://rustsec.org/advisories/RUSTSEC-2026-0386.html) (informational, unsound `AsyncFd`; patched ≥1.51.6,<1.52 or ≥1.53.3) | tokio 1.48.0 | **Yes, by version** | Not compiled: `AsyncFd` is behind `cfg(all(unix, feature="net"))`. The resolved tokio features are only rt/signal/libc/mio/signal-hook-registry. Bumping tokio is an owner pin decision |
| [RUSTSEC-2026-0382](https://rustsec.org/advisories/RUSTSEC-2026-0382.html) (distrusted intermediates) | rustls-webpki 0.103.16 | No (first patched) | Installer TLS |
| [RUSTSEC-2026-0381](https://rustsec.org/advisories/RUSTSEC-2026-0381.html) (root store) | webpki-roots 1.0.11 / 0.26.11 shim | No | Installer TLS roots (bundled, not native store) |
| [RUSTSEC-2026-0346](https://rustsec.org/advisories/RUSTSEC-2026-0346.html)–[0349](https://rustsec.org/advisories/RUSTSEC-2026-0349.html), [0285](https://rustsec.org/advisories/RUSTSEC-2026-0285.html) | rustls 0.23.46 | No (first patched for 0346–0349) | Installer TLS |
| [GHSA-3pv8-6f4r-ffg2](https://github.com/advisories/GHSA-3pv8-6f4r-ffg2) (PAX desync, ≤0.4.45); RUSTSEC-2026-0067/0068 | tar 0.4.46 | No (first patched) | Installer `entries()` read of a SHA-verified archive; no unpack |
| [RUSTSEC-2026-0385](https://rustsec.org/advisories/RUSTSEC-2026-0385.html); [GHSA-3rjw-m598-pq24](https://github.com/advisories/GHSA-3rjw-m598-pq24) (aarch64 wrong results, <0.5.4) | ctutils 0.4.6; cmov 0.5.4 | No (cmov first patched) | sha2/digest path, relevant on Apple Silicon |
| Build-only: RUSTSEC-2026-0429/0367–0369, [GHSA-m665-v7pm-7grj](https://github.com/advisories/GHSA-m665-v7pm-7grj) (zip <9.0.5); RUSTSEC-2026-0391–0393 (zstd), 0395–0406 (zstd-safe), 0410 (zstd-sys, wasm32); RUSTSEC-2023-0004 (bzip2); RUSTSEC-2021-0119 (nix) | zip 9.1.2, zstd 0.14.3, zstd-safe 8.2.0, zstd-sys 2.1.2, bzip2 0.4.4, nix 0.31.3 | No | sherpa-onnx-sys build script only |

Older records for ring, untrusted, idna, zerovec, smallvec, hashbrown, mio, rustix,
base64, once_cell, sha2, zlib-rs, time, shlex and bumpalo exclude the locked
versions. 120 entries have no record in any source, including ureq 2.12.1,
flate2, miniz_oxide, toml 0.9.8 and serde_json. "No record" is not a clean bill.
The bundled C code (bzip2 1.0.8, zstd 1.5.7), sherpa-onnx/ORT binaries and git
dependencies are outside these databases. ONNX Runtime advisories still need a
source/build mapping for the third-party ORT build.

Installer HTTP behavior was checked in [ureq 2.12.1 source](https://github.com/algesten/ureq/blob/ba4555d54fd72e16fc737f7e8fcc812efb131260/src/unit.rs#L346-L354):
- `https_only(true)` rejects http redirect targets before connecting.
- `redirects(5)` follows at most four hops.
- Without `proxy-from-env`, proxy environment variables are not read ([agent.rs L267-L290](https://github.com/algesten/ureq/blob/ba4555d54fd72e16fc737f7e8fcc812efb131260/src/agent.rs#L267-L290)).
- With only `tls`, no Accept-Encoding is sent and nothing is decompressed.
- Roots come from bundled webpki-roots.
- `User-Agent: ureq/2.12.1` identifies the library version.

`cargo tree -e normal,features` confirms the runtime ureq has only `tls`, even
with `inference-candidate`. The sherpa-onnx-sys build-dependency instance has
default/gzip/proxy-from-env and **does** honor proxy variables. That is one more
reason the network-denied build matters.

No exploit attempt, scanner, new tool or dependency was used.

## Provenance, tokenizer, interface and operator follow-up — 2026-11-09

Owner decisions for this pass, all 2026-11-09:
- **D1:** native F1/F2 reproduction is no longer required once PR #37's guard
  merges. Acceptance asks for negative cases on *reachable* findings, and the
  backend never calls the native WAV reader. The defects stay unrepaired upstream.
- **D2:** review the tokenizer and native interface, and record the operators
  the graphs use. Reviewing ORT kernel code for those operators is deferred.
- **D3:** trace public build records only. No rebuild, no upstream request.

Evidence boundary:
- Read-only GitHub API reads of public releases, workflow runs and job logs.
- Pinned-source reads: S; the simple-sentencepiece v0.7 tarball, whose SHA256
  matches S's cmake pin; and a sparse `cmake/` + `tools/ci_build/` checkout of ORT
  tag v1.28.2.
- The three ONNX graphs and `tokens.txt`, downloaded from the manifest URLs and
  SHA256-verified. `bpe.vocab` was read from the first MiB of the `.nemo` with an
  HTTP range request; its SHA256 matches the manifest.
- Python standard-library scratch scripts and gcc on a Linux x86-64 orb. These
  were removed afterwards.

No native library was loaded, no inference ran, sherpa-onnx/ORT were not built,
and no scanner, new tool or dependency was used.

### Build provenance (remaining item 2)

| Artifact | Public build record | Build facts from the log |
| --- | --- | --- |
| `sherpa-onnx-v2.0.1-osx-arm64-shared-no-tts-lib.tar.bz2` | Release v2.0.1; tag → `af2d8d81` (= S). Uploaded by `github-actions[bot]` 2026-10-26T16:39:50Z. The GitHub asset digest equals our pin `ac5594ad…f2e3`, and `updated_at` is 2 s later, so it was not replaced afterwards. [Run 40348432449](https://github.com/k2-fsa/sherpa-onnx/actions/runs/40348432449), job 121661567048 "Release shared tts-OFF macos-latest arm64;x86_64" | Image macos-26-arm64 20261021.0445.8, AppleClang 21.0.0, CMake 4.4.4. Checks out `refs/tags/v2.0.1` at `af2d8d81`, then `new-release.sh` rewrites version/sha1/date strings before compiling. Release, `BUILD_SHARED_LIBS=ON`, TTS/GPU/sanitizer off, `LINK_LIBSTDCPP_STATICALLY=ON`. The ccache restore found no cache; its 14/353 hits are within the run. A universal2 build is `lipo -thin arm64`'d, ad-hoc re-signed (`codesign --force --sign -`), tarred and uploaded by `svenstaro/upload-release-action` (SHA `29e53e9`, `overwrite: true`) |
| `onnxruntime-osx-universal2-1.28.2.zip` (S's pin `b5033fb6…0191`) | csukuangfj/onnxruntime-libs release v1.28.2. Uploaded by `github-actions[bot]` 2026-09-04T17:20:41Z; the digest equals the pin. [Run 33892225135](https://github.com/csukuangfj/onnxruntime-libs/actions/runs/33892225135), job 101086390048 "macos-15-intel universal2". It ran on a push to branch `test-ci` at `bb069649`, an unsigned "Small fixes" commit 24 ahead of and 5 behind `master` | Checks out microsoft/onnxruntime `refs/tags/v1.28.2` → `33ca962` (= O). `build.py --config Release --build_shared_lib --use_coreml` for arm64 and x86_64, then combined. ccache was restored from the previous day's key but had 0/2060 hits. `USE_COREML=ON`, `DISABLE_CONTRIB_OPS=OFF`, `ENABLE_PYTHON=OFF`, `MINIMAL_BUILD=OFF`, training and every GPU/NPU provider off. The same zip was also pushed to Hugging Face `csukuangfj2/onnxruntime-libs` |

What this shows:
- Each binary traces to a public CI job that checked out the expected source tag.
- Every `FetchContent_Declare` in S's `cmake/*.cmake` has a `URL_HASH`, so the
  archive's dependency downloads during configure are SHA256-pinned. That includes
  the ORT zip above, and portaudio, which is fetched over plain `http://`.
- `ENABLE_LANGUAGE_INTEROP_OPS` is defined nowhere in the tag's `cmake/` or
  `tools/ci_build/`. Per source, the interop custom-op loading guarded at
  O `inference_session.cc:1197,1293,1331,1373,1407` is therefore compiled out.
- The CoreML provider is compiled in, but the worker selects plain `cpu`.

What it does not show:
- The GitHub attestation API returns 404 for both digests, so neither file has a
  build provenance attestation.
- Matching build records are not reproducibility. Workflows on a maintainer
  branch, with repository write tokens, produced and uploaded these bytes. GitHub's
  digest records only what was uploaded.
- **That these bytes were built from this source remains unproven.**
- The ORT library is a third-party build from Microsoft source, not a Microsoft
  release binary.

Advisory consequence: all five ORT 1.24.3 security-fix PRs are ancestors of
`33ca962`. The GitHub compare API reports them 849, 865, 861, 801 and 815 commits
behind it, 0 ahead:
- [#27444](https://github.com/microsoft/onnxruntime/pull/27444) GatherCopyData
- [#27430](https://github.com/microsoft/onnxruntime/pull/27430) external data from bytes
- [#27419](https://github.com/microsoft/onnxruntime/pull/27419) Resize
- [#27543](https://github.com/microsoft/onnxruntime/pull/27543) RoiAlign
- [#27518](https://github.com/microsoft/onnxruntime/pull/27518) LoRA

This settles the earlier "packaged applicability unresolved" entry at source
level, subject to the binary correspondence gap above.

### Operator inventory (remaining item 3, inventory only)

Method:
- A standard-library protobuf wire-format walker reads ModelProto, GraphProto and
  NodeProto, recursing into graph-valued attributes.
- An independent byte search for the encoded NodeProto `op_type` field reproduced
  the counts for encoder MatMulInteger (217), ConvInteger (77), LayerNormalization
  (120), Where (73) and Softmax (24), decoder DynamicQuantizeLSTM (2) and joiner
  MatMulInteger (3).

| Graph | Header | Nodes / initializers | Operators (count) |
| --- | --- | --- | --- |
| encoder.int8.onnx | IR 8, `ai.onnx` opset 17, producer `onnx.quantize` 0.1.0 | 5,654 / 1,229 (612 float, 588 uint8, 29 int64) | Add 205, And 2, Cast 426, Concat 221, Constant 1,661, ConstantOfShape 51, ConvInteger 77, Div 27, DynamicQuantizeLinear 223, Equal 1, Expand 2, Floor 3, Gather 149, LayerNormalization 120, Less 1, MatMul 72, MatMulInteger 217, Mul 733, Not 2, Pad 48, Range 1, Relu 3, Reshape 295, Shape 175, Sigmoid 96, Slice 123, Softmax 24, Split 24, Squeeze 24, Sub 2, Tile 1, Transpose 244, Unsqueeze 328, Where 73 |
| decoder.int8.onnx | IR 8, `ai.onnx` 17 + `com.microsoft` 1 | 30 / 17 (7 float, 2 uint8, 8 int8) | Cast 1, Concat 2, Constant 14, DequantizeLinear 1, Gather 1, Identity 1, Slice 4, Squeeze 2, Transpose 2, **com.microsoft::DynamicQuantizeLSTM 2** |
| joiner.int8.onnx | IR 8, `ai.onnx` 17 | 26 / 12 (6 float, 6 int8) | Add 4, Cast 3, Constant 2, DynamicQuantizeLinear 3, MatMulInteger 3, Mul 6, Relu 1, Transpose 2, Unsqueeze 2. Output last dimension 1030 |

Structure:
- The union is 36 standard operators plus one contrib operator.
- No graph has subgraphs (no If/Loop/Scan), model-local functions or external-data
  initializers. ORT's external-data loader (O `tensorprotoutils.cc`) is therefore
  not exercised by these assets.
- Encoder metadata includes `vocab_size=1024`, `feat_dim=128`,
  `subsampling_factor=8` and `model_type=EncDecRNNTBPEModel`.
- Resize, RoiAlign, GatherND and LoRA (the 1.24.3 fix sites other than Gather) do
  not appear.

For the deferred kernel review, the higher-risk surfaces are:
- The shape-driven allocation operators: Pad, Tile, Expand, Range,
  ConstantOfShape, Reshape and Slice. Their sizes follow the audio length.
- The integer-quantized kernels: ConvInteger, MatMulInteger and
  DynamicQuantizeLinear.
- The contrib DynamicQuantizeLSTM.
- Nodes produced by graph optimizers. Sherpa sets no optimization level for plain
  `cpu` (S `session.cc:209–310`), so ORT's default applies and optimizers can
  rewrite these nodes before any kernel runs. The executed kernel set is not
  exactly this list.

### Tokenizer and vocabulary path

Pinned tables:
- `tokens.txt` is exactly `bpe.vocab`'s 1,024 pieces in order plus `<blk>` at ID
  1024. IDs run contiguously from 0 to 1024, with no duplicate pieces.
- S `offline-recognizer-transducer-nemo-impl.h:228–276` exits unless `<blk>` is
  last and the line count equals the model's vocab size (metadata + 1). The joiner
  width 1030 is 1025 tokens plus 5 TDT durations.
- `bpe.vocab` has 1,024 two-field lines and 205 single-character pieces. Every
  piece except `<unk>` is made only of single-character pieces. So the worker's
  single-character check (`backend/src/bin/hagig-inference-worker.rs:24–36`)
  guarantees that every accepted term can be segmented into vocabulary pieces.
- `#` and `@` are not single-character pieces, so terms containing them are
  rejected by that check. Configuration validation also rejects `:`, `/`, control
  characters and non-space whitespace (`backend/src/config.rs:74–85`).

Native path: hotwords → `/`→newline regex (nemo-impl `118–126`) →
`EncodeHotwords` (S `utils.cc:104–206`) → ssentencepiece `Encode` → `EncodeBase`
(`utils.cc:21–101`). `EncodeBase` maps each piece through the symbol table. A
non-member piece beginning with `:` or `#` reaches `std::stof` (`utils.cc:53,57`),
which throws on malformed numbers. Any other non-member piece is logged with its
full line (`utils.cc:65–68`). `CreateStream` logs the entire hotword string on
failure (nemo-impl `126`).
- **Reachability:** with the pinned tables and the backend's two checks, every
  emitted piece is in `tokens.txt`. The out-of-vocabulary, `stof` and
  hotword-logging paths are therefore unreachable.
- **If reached:** native stderr is null in both launchers
  (`backend/src/launcher/linux.rs:29`, `macos.rs:43`). The non-WASM
  `SHERPA_ONNX_LOGE` writes to stderr, not stdout (S `csrc/macros.h:22–52`), so
  these logs cannot reach the private reply pipe. A C++ exception escaping an
  `extern "C"` call is undefined behaviour at the Rust boundary, because the
  declarations are not `C-unwind`. The worker is expected to terminate, and process
  separation contains it.

simple-sentencepiece v0.7:
- `LoadVocab` (`ssentencepiece.cc:248–260`) exits the process on a malformed line.
- `GetDag` (`64–78`) passes the remaining byte count as the result limit to darts
  `commonPrefixSearch`, then iterates the returned count. Darts documents that
  count as possibly larger than the limit (`darts.h:287–290`). It is bounded here
  because matches from one position are distinct non-empty keys with distinct
  lengths, at most the remaining bytes. This is a latent pattern, not a reachable
  defect.
- With no `<0x00>` piece, byte fallback is off; unmatched bytes become `<unk>`
  (`115–150`).
- The constructor starts a thread pool sized to `hardware_concurrency()`
  (`ssentencepiece.h:39–52`). The single-string `Encode` used for hotwords does not
  use it.

**Correction to the F3 row above:** the worker accesses sherpa objects
sequentially on one Rust thread, but the process is not single-threaded. ORT's
thread pools are configured with `num_threads=2` (`session.cc:219–222`), and this
idle tokenizer pool also exists. F3 containment depends only on sequential stream access, which
still holds.

Other native code reviewed:
- `SymbolTable::operator[](id)` uses `.at()` (S `symbol-table.cc:192`), so an
  out-of-range ID throws and aborts rather than reading out of bounds.
- The TDT beam-search decoder (S
  `offline-transducer-modified-beam-search-nemo-decoder.cc:240–253`) splits the
  joiner output at the vocab size without checking that the output is wider. A
  hostile, narrower joiner would read past the logits. The hash-pinned joiner
  avoids this; it is a model-trust hazard, not reachable with pinned assets.

### Rust ↔ C interface

Layout check:
- I transcribed every `repr(C)` field list reachable from
  `OfflineRecognizerConfig` in S `rust/sherpa-onnx-sys/src/{offline_asr,online_asr}.rs`
  into C, then compiled it against the real `c-api/c-api.h`.
- For each struct, `sizeof`, every field's `offsetof` and every field's size were
  compared. A field name missing from the header would fail to compile.
- Result: **24 structs, 109 fields, no mismatch.** `OfflineRecognizerConfig` is
  624 bytes on gcc x86-64 Linux.
- The fields are only pointers, `int32_t` and `float`, whose size and alignment
  are the same on aarch64 Darwin. No Apple-target compile was run.
- Counterfactual: swapping `num_threads` and `debug` in a copy produced two
  reported mismatches.

The nine entry points used match the header's parameter and return types:
create/destroy recognizer, create stream (with and without hotwords), destroy
stream, accept waveform, decode, and get/destroy result JSON.

Wrapper behaviour (S `rust/sherpa-onnx/src/offline_asr.rs`):
- `create_stream*` (`702–712`) does not null-check. The C API returns null only for
  a null recognizer (`c-api.cc:750–756`), which `create` already excludes.
- `accept_waveform` casts the length to `i32` (`756`). The worker protocol caps
  input at 4,800,000 samples.
- `get_result` (`762–774`) copies the JSON, frees it with the matching destroy
  call, and maps a parse failure to `worker_failed`.
- `CString::new(..).unwrap()` panics on NUL; configuration already rejects
  control characters.

Not reviewed:
- Unused C API functions.
- Exception behaviour of every entry point. The earlier pass found only
  recognizer creation catching exceptions.
- Apple-target layout.

### Remaining #25 acceptance

1. ~~Isolated native negative cases for F1/F2~~. Not required by owner decision
   D1 once PR #37 merges. The upstream defects remain unrepaired.
2. Source/binary correspondence: the build records are traced (above). That the
   bytes match the source is unproven for both the sherpa-onnx archive and the
   third-party ORT build. Closing this needs a reproducible rebuild or a
   publisher attestation, neither available.
3. ORT kernel code review for the operators above, the optimizer-rewritten graph
   and contrib DynamicQuantizeLSTM. This is deferred; tokenizer and interface
   review is done.
4. Recheck the packaged artifact in both modes after any fix. No fix is planned.
5. An explicit adoption decision for the unresolved items.

No exploit attempt, scanner, new tool or dependency was used.
