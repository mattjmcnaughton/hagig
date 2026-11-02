# Issue #6 pinned-source and provenance follow-up

2026-10-28. Investigation of the preserved candidate, **not adoption clearance**.
No dependency versions, model pins, or acquisition recipe changed.

## Acquired bytes and build boundary

Under the original bounded-wave authorization to evaluate the preserved pinned
S1 candidate, existing `acquire.sh` ran in a fresh ignored `.agentic/inference`
directory. This was not a new asset-specific owner approval. All ten required
SHA256SUMS entries passed,
including original NVIDIA archive, model/tokenizer files and native libraries.
The native archive contains a directory plus three `.so` files, **no license or
notice bundle**. Matching the retained hashes establishes identity to the evaluated
S1 bytes, not reproducible publisher provenance or native-source equivalence.

Rust 1.90.0 release and test builds succeeded on Linux x86-64, with
`SHERPA_ONNX_LIB_DIR` pointing at those local libraries. Cargo resolved the existing
locked source/crates (no lockfile change); subsequent builds ran `--offline
--locked`. Inspecting the pinned
[sys build script](https://github.com/k2-fsa/sherpa-onnx/blob/af2d8d81dbfa61c4cea4c568da78f3982edca005/sherpa-onnx/rust/sherpa-onnx-sys/build.rs#L110-L126)
confirms the local override bypasses download. Its default
[ureq path](https://github.com/k2-fsa/sherpa-onnx/blob/af2d8d81dbfa61c4cea4c568da78f3982edca005/sherpa-onnx/rust/sherpa-onnx-sys/build.rs#L193-L215)
does make a network request and uses environment proxies. Cargo offline mode
alone must not be confused with build-script network enforcement.

## Rust dependency declarations and actual Linux graph

`cargo metadata --locked --format-version 1` enumerated 144 packages. All 143
external packages declare license expressions; only this unpublished local spike
lacks one. Declarations are not license-text review or legal clearance. Notable
expressions beyond ordinary MIT/Apache alternatives include Unicode-3.0,
CDLA-Permissive-2.0, bzip2-1.0.6, BSD-3-Clause, ISC, Zlib, and LLVM-exception
alternatives. No claim that every declared alternative must be selected together.
Actual notices and applicable distribution obligations remain to be collected.

The first `cargo metadata --offline` attempt failed because a locked target-only
crate (`cfg_aliases`) was absent. An online metadata run downloaded the remaining
already-locked crates, then succeeded. This was not a dependency addition.

`cargo tree -e normal --offline --locked` on Linux shows the Rust normal graph as
serde/serde_json and sherpa-onnx/sys (plus their normal/proc-macro dependencies).
`cargo tree -i rustix` places it under xattr → tar → sys **build dependencies**.
`cargo tree -i nix` has nothing to print for this target, despite the lockfile
entry. These commands distinguish build/runtime and target selection; they do
not enumerate statically embedded native components or establish macOS behavior.

## Exact hotword source path and remaining representability uncertainty

At the pinned sherpa revision,
[CreateStream](https://github.com/k2-fsa/sherpa-onnx/blob/af2d8d81dbfa61c4cea4c568da78f3982edca005/sherpa-onnx/csrc/offline-recognizer-transducer-nemo-impl.h#L118-L129)
rewrites `/` to newline; failure of EncodeHotwords logs the hotword contents but
still proceeds. In
[EncodeHotwords](https://github.com/k2-fsa/sherpa-onnx/blob/af2d8d81dbfa61c4cea4c568da78f3982edca005/sherpa-onnx/csrc/utils.cc#L104-L208),
a word beginning `:` is treated as a score, and ordinary text after a score is
rejected. Thus the spike rejects slash and colon syntax before this boundary,
without pretending the native API is a fallible validation API.

The pinned CMake declaration selects simple-sentencepiece **0.7**, archive
SHA256 `1748a822060a35baa9f6609f84efc8eb54dc0e74b9ece3d82367b7119fdc75af`.
That exact source archive was fetched and its hash verified; its LICENSE contains
Apache-2.0. In `ssentencepiece/csrc/ssentencepiece.cc`, `Encode` normalizes words
with the ▁ prefix and runs scored dynamic programming; `Cut` substitutes `<unk>`
per unmatched byte unless byte fallback applies. The evaluated `tokens.txt` and
`bpe.vocab` both contain `<unk>` at entry zero. A term can therefore pass native
symbol lookup without its spelling being representable usefully. An emoji control
returned success without warnings in both legacy and candidate worker checks.
This does not prove contextual biasing of that emoji worked. Source and finite
runtime observation support retaining this blocker, not a blanket Unicode ban
or an invented Rust tokenizer approximation.

## Still open

- Native archive build configuration/SBOM, complete license texts/notices, ORT and
  other transitive source equivalence; signed/reproducible binary provenance.
- Model/tokenizer CC-BY-4.0 attribution, conversion/quantization toolchain provenance
  and redistribution review, as retained in FINDINGS.md and REVIEW.md.
- Complete native/transitive privacy inspection. This follow-up reviewed selected
  hotword/build paths only, not every ONNX/ORT/provider or persistence path.
- Fresh observed syscall network/write evidence (strace unavailable), separate
  enforced network-denial controls, and macOS unified logging/crash-report behavior.
  Namespace execution and empty inherited diagnostics do not establish these.
- Real tokenizer-aware reject/accept contract and human speech/no-speech controls.
  Structural validation alone does not satisfy #6 or AC9 in full.

## Resumed local inventory, 2026-11-02

This section updates availability, not the historical evidence above. Existing
PR18 source at `095ed8102ebef43b1a0e56a2af45829b8c85c5a5` was reused unchanged.
No acquire.sh, upstream model/native download, new dependency/tool, or speech gate
was run or introduced. The shared recovered assets/cache were read-only.

[Local inventory](evidence/local-inventory-2026-11-02.json) records sizes and full
SHA256 values against the unchanged SHA256SUMS, plus all 141 registry packages'
exact versions, declarations, crate digests and packaged named license/notice
file digests. The selection rule is explicit in that artifact; it is an inventory,
not legal review, a notice bundle, source audit, or an enabled native/runtime SBOM.

- **9/10 non-fixture manifest entries locally present and matching**: native
  archive, five model/tokenizer files, three shared libraries. `original.nemo`
  is missing. None of the nine original WAV fixtures was recovered. No asset is
  reacquired to hide that gap. The model card/license claims in provenance.json
  remain historical metadata, not newly inspected publisher/license documents.
- The recovered native archive contains only directories and three `.so` files;
  no license/notice bundle. Matching bytes do not establish native build flags,
  embedded components, ORT source correspondence or reproducible provenance.
- All **141 registry .crate archives match their Cargo.lock checksum**. Each has
  a license declaration; **140/141 contain filename-selected license/notice
  texts**. `r-efi 6.0.0` lacks such named files, but its README has a License
  section; absence from this filename inventory is not absence of all notices.
  Its declaration is `MIT OR Apache-2.0 OR LGPL-2.1-or-later`: an alternative,
  not a claim that LGPL is the required selected license. Target-only and build
  dependencies remain distinguished from Linux normal/runtime use.
- The two Git packages share sherpa source revision
  `af2d8d81dbfa61c4cea4c568da78f3982edca005`. Its root Apache-2.0 LICENSE SHA256
  is `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30`.
  The retained simple-sentencepiece 0.7 archive still matches its pinned hash;
  Apache-2.0 LICENSE inside has SHA256
  `c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4`.
  These texts do not cover the opaque native archive's complete obligations.

The exact tokenizer tables have 1,024 BPE rows and 1,025 token rows. Splitting
each BPE row at its final tab and token row at its final ASCII space yields
identical ordered spellings for the first 1,024 entries; the extra token is
`<blk>`. Both entry zero spellings are `<unk>`; neither table contains the robot
emoji spelling. Table consistency does **not** implement the pinned tokenizer's
normalization/scored segmentation, identify per-term unknown tokens, or certify
hotword usefulness. No guessed Rust tokenizer or Unicode ban was added.

### Offline build recovery and regression checks

Rust 1.90 release build/test/Clippy and 42 CLI contract checks passed using an
isolated copied Cargo home/target, `--offline --locked`, local
`SHERPA_ONNX_LIB_DIR`, and `unshare -Urn`. fmt --check passed. Five parser tests
passed. These are exploratory/build regressions, not a new /prove capture.

Preserved setup failures: the recovered registry lacked config.json; copying the
existing local registry config into the isolated copy resolved that. A second
build failed because recovered expanded `cc` sources lacked `src/target/` modules.
Moving only the isolated expanded registry source aside let Cargo re-extract its
already cached, checksum-matching archives; no source patch/download was needed.
The first CLI run lacked `LD_LIBRARY_PATH` and failed its exact-stderr assertion;
ldd showed libsherpa-onnx-c-api.so not found. Setting that variable to the local
native library directory made the unchanged harness pass. This is not a bundle
relocatability test or a native failure wrongly attributed to vocabulary parsing.

### Bounded runtime privacy/failure exploration (not acceptance proof)

Installed strace 6.1 now permits finite observation. An inline Python stdlib probe
used temporary 3-second 16 kHz mono PCM16 all-zero WAV, empty/invalid/emoji
vocabularies, and a temporary invalid encoder with other model files symlinked
read-only. No human audio or recovered speech was available. Each case below ran
once with no namespace wrapper and once with namespace established **before**
the tracer. These are laboratory launch arrangements, **not** product
required/disabled-mode integration or independent connectivity-denial controls.

| Case | Client exit / stable error | Client output | Native stderr writes to discard sink (each arrangement) |
| --- | --- | --- | --- |
| Missing model | 1 / model_missing | Empty | 0 |
| Corrupt encoder | 1 / model_invalid | Empty | 3 |
| Malformed vocabulary | 1 / vocabulary_invalid | Empty | 0 |
| Missing audio | 1 / audio_invalid | Empty | 3 |
| Digital silence, empty vocabulary | 0 / none | **Nonempty: safety failure retained** | 0 |
| Digital silence, emoji vocabulary | 0 / none | **Nonempty: safety failure retained** | 0 |
| Crash after real result seam | 1 / worker_failed | Empty | 0 |
| Cancel after buffered result seam | 130 / cancelled | Empty | 0 |
| Hold-after-result, 8-second deadline | 1 / deadline_exceeded | Empty | 0 |

For all 18 completed cases, observed network syscalls were zero; writable
open/openat/creat calls were limited to /dev/null within the traced supervisor
and descendants. Error stderr matched the exact stable supervisor message; no
path/vocabulary canary reached the client. A separate direct native corrupt-load
control really emitted the synthetic path canary into memory-only stderr. A
socket-creation-only observer control was detected; it made no remote connection.

Tracing used `strace -f -qq -s 0 -yy -e
trace=%network,%file,write,writev,pwrite64,process`, with `-o` pointing to an
in-memory memfd passed to the tracer; Python client stdout/stderr were also held
only in memory. Core limit was (0,0), bytecode writes disabled, temporary inputs
removed on exit. No transcript, raw native diagnostic or syscall trace persisted.
The trace does not cover every persistence mechanism (for example mapped writes,
OS-managed logging/swap/crash services); finite zero counts are not guarantees.

An initial namespace exploration traced **unshare itself** and failed the strict
write-open assertion: it opened /proc/self/{setgroups,uid_map,gid_map} for namespace
setup. A follow-up classified these three setup writes, found no other writable
opens besides /dev/null and no network calls for that missing-model run. The
completed namespace matrix placed strace after unshare to measure worker scope;
the failed broader-scope assertion is retained here, not called a native leak or
silently whitelisted in verify_worker.py. That verifier is unchanged and still
blocked on its original speech fixture/exact reference; none of these runs passes
its full speech, SIGINT, same-supervisor recovery or input-hash matrix.
