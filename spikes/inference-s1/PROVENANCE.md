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
