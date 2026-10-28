# Issue #3 preservation review

Reviewed 2026-10-27. **Preserve for further evaluation; do not adopt.**

## Origin and ownership

The source is the local/uncommitted `experiments/inference-s1/` from
[the source thread](https://ampcode.com/threads/T-01a17af0-7691-7758-9dce-3cbd402087f1),
retrieved with `download_thread_changes`, capture
`cap_01a17d02f8c670ef92212042b9213ce0`. It was not reconstructed from a summary or
assumed present on main. Originals and generated assets remain source-thread
owned. This review owns only copies under `spikes/` on
`issue-3-preserve-inference-spike`, created from fetched `origin/main`
`b36ab9986a2af44ccb428ec212e61233a3e7fe4f`.

All three Rust sources, Cargo manifest/lock, three Python reproduction harnesses,
corpus, hotwords and SHA256SUMS are byte-identical to the capture (11 files).
Changes are relocated documentation commands, corrected upstream line references,
explicit evidence/tooling limits, scoped build/cache ignores, and acquisition
checks requiring every named artifact. `acquire.sh` previously used
`--ignore-missing`; the reviewed recipe fails for missing/corrupt/unlisted assets.
It remains an explicit disposable-spike acquisition script, not an atomic or
hostile-archive-safe production installer. Use a fresh ignored destination.

No backend, macOS, shared-launcher, constitution, PRD or TDD changes are included.
The TDD's broad historical status wording is not corrected here: its current
network-isolation decision remains authoritative and unmodified.

## Findings to retain, not explain away

| Finding | Review disposition |
| --- | --- |
| Mixed vocabulary benefit | Hagig spelling improves, Parakeet casing improves; Ghostty and sherpa-onnx still fail. Case-insensitive term recovery is only 1/4 → 2/4; four spoken controls unchanged. Nine synthetic fixtures cannot pass AC8's 10+10 human corpus. |
| Silence hallucination | Both benchmark modes and the isolated worker emit nonempty text on digital silence. Process separation does not fix speech detection; blocks production delivery/AC9. |
| Malformed hotwords | Native library logs and skips malformed input while still returning a successful transcript. Discarding diagnostics is not rejecting invalid vocabulary. |
| Native diagnostic canaries | Corrupt-path and malformed-vocabulary positive controls really emit sensitive values. Default worker descriptors are discarded before native execution; only sanitized summaries are retained. This is containment of tested descriptors, not all OS/native logging. |
| Buffered result + crash/cancel/deadline | Verifier requires a real private reply before these failures, then checks empty client stdout and worker reaping. Same-supervisor recovery is demonstrated only for tested paths. R5's startup-interruption cleanup hole is reproduced separately; app/server lifecycle and clipboard races are not established. |
| Network enforcement | `worker_probe.py` itself does not enforce isolation. Only externally wrapped `unshare -Urn` runs do. Default unrestricted runs are synthetic observation controls, not a constitutional production launch path. |
| Packaging/performance | Developer `LD_LIBRARY_PATH`, Linux CPU and tiny synthetic clips do not establish relocation, Mac signing/loading, M4 latency, five-minute bounds, or human usefulness. |

## Acquisition and provenance review

Pins/URLs live in `acquire.sh`, evaluated SHA-256s in `SHA256SUMS`, and historical
metadata in `evidence/provenance.json`. Independently checked from this review orb:

- GitHub release API: native v2.0.1 archive digest matches
  `ce437357915491e6f2754b52bec7dcf62ff6fc6aaed9cdcd66f17807bbaef374` (9,374,461 bytes).
- Hugging Face pinned-tree LFS metadata: all three ONNX graphs and original NVIDIA
  `.nemo` SHA-256s match the manifest. Pinned `tokens.txt` was fetched separately
  and matches `ec182b70dd42113aff6c5372c75cac58c952443eb22322f57bbd7f53977d497d`.
  Extracted vocabulary/native-library bytes are checked against existing assets
  in source-environment reruns; no multi-GB assets were transferred into this orb.
- Both pinned model cards declare **CC-BY-4.0**. The NVIDIA card links
  [CC-BY-4.0 terms](https://creativecommons.org/licenses/by/4.0/legalcode.en).
  NVIDIA attribution, original model/tokenizer source, exporter identity and
  conversion/quantization notice are required before distributing those assets.
  The int8 export's card contains only license metadata: it does not supply
  conversion commands/toolchain provenance. No model is distributed here.
- Pinned sherpa-onnx source and Rust package metadata declare Apache-2.0.
  `sherpa-onnx/rust/sherpa-onnx-sys/build.rs:115–126,203–215` confirms that the local
  library override bypasses the default network download, which lacks a publisher
  checksum check. Cargo `--offline` alone does not sandbox build-script networking;
  set the override. Existing transitive build dependencies include `bzip2`, `tar`,
  `ureq`, and `zip`; preserving the locked candidate is not approving them anew.
- Checked the pinned Rust/C-API hotword path, NeMo dispatch/decoder, native logging
  macro and malformed-hotword branch. Corrected stale header references in the
  findings: full-vocabulary logging is at `csrc/offline-recognizer-transducer-nemo-impl.h:124–127`.

Publisher metadata and evaluated hashes are identification/integrity evidence,
not reproducible native-build attestation. Full native/transitive licenses,
notices/SBOM, vulnerability/privacy review, conversion provenance and binary/source
equivalence remain open. Neither model-card metadata nor this review clears
training data rights or approves production redistribution.

## Evidence boundaries and reproduction

- **Source:** partial upstream inspection and the exact local harness; no claim of
  whole-stack privacy clearance. See `FINDINGS.md` for inspected ownership paths.
- **Runtime network/write observation:** historical `validation.txt` and worker
  JSONL summarize selected syscalls in finite success/failure cases. Zero observed
  attempts does not establish an absolute absence of outbound channels. GNU time
  reports 48 filesystem-output units; it is not the syscall write audit and does
  not prove zero kernel/OS persistence. The no-writable-open claim concerns only
  the traced process, not deliberate shell evidence redirection.
- **Blocked network:** namespace inference plus an independent direct-connect
  failure is separate evidence. It does not establish Mac enforcement, all
  IPv4/IPv6/DNS escape controls, or inherited-resource safety.

`evidence/{baseline,observed,blocked}.jsonl` deliberately retain synthetic
transcripts, references and timings, including failures. `baseline.time` retains
the historical measurements with the command-path line omitted and labeled.
Other selected historical files are unchanged. Raw `.trace`, failure `.stderr`,
empty logs, model/audio/native binaries and scratch/debug outputs were excluded;
the originals were not deleted. Raw trace counts are therefore source-reported
historical summaries, not independently re-auditable raw captures in this copy.
Worker verification uses RAM-only raw diagnostics/traces, printing only sanitized
outcomes. The three Python files are required reproduction harnesses, not ad hoc
debug scripts. Never use the benchmark or verifier on personal audio/vocabulary.

Run recipes from the repository root: [benchmark](README.md#reproduce),
[worker checks](WORKER.md#reproduce-from-the-repository-root). Write new outputs
under ignored `.agentic/inference/`, not over historical evidence. Fixtures are
generated locally from public synthetic text, no microphone or remote TTS.

### Checks executed by this review orb

Python AST parsing (three files), `bash -n spikes/inference-s1/acquire.sh`, exact
copy comparisons (11 files), historical JSONL assertions (108 decodes, paired
outputs, negative controls; 11 matching worker records), required-hash helper
checks (valid accepted; missing/corrupt/unlisted rejected), and publishable-file
scans passed. No installation or new dependency/tool was introduced. Initial
scratch assertions incorrectly counted silence as a passing spoken control and
assumed small HF files had LFS metadata; corrected checks explicitly separate
silence and fetch `tokens.txt` directly. No product failure was hidden.

This orb has no Cargo/Rust, strace, eSpeak or existing model assets. It did not run
native inference. Reruns of the relocated copy use the source thread's existing
execution environment and must be read as **source-thread execution reports**,
not independent local execution. Their commands/results are retained separately
in [review-source-rerun.txt](evidence/review-source-rerun.txt) and
[observed](evidence/review-worker-observed.jsonl)/[blocked](evidence/review-worker-blocked.jsonl)
worker summaries. Downloaded bytes match the source-reported SHA-256s:
`3bb3c2644b347d2dd95443f46f4f8e4700d77f347ea9441bbf77ebd7082c4204`
for the report, `6b4facb01fd231a36561ade752101c45de92741ee31891c8421a2819ff78f885`
for each worker summary. Local checks also confirmed those summaries match the
historical records exactly. [Local checks](evidence/review-local-checks.txt) are
recorded separately.
No fresh multi-GB download or clean-machine build is claimed.

### Relocated-copy rerun results (source environment)

- Fresh isolated Cargo target: `unshare -Urn cargo +1.90.0 build --release --offline
  --locked --manifest-path spikes/inference-s1/Cargo.toml` passed in 51.056 s.
  Formatting, shell/Python syntax, all 19 asset/WAV hashes, regenerated nine WAV
  hashes and all 1,024 tokenizer pieces passed. Source/config copies unchanged.
- Available and blocked benchmark runs each match all 36 original non-timing
  records; mixed vocabulary results and all silence failures remain present.
- `python3 spikes/inference-s1/verify_worker.py ...` and its `unshare -Urn` repeat
  passed with 11 identical records each. Seven traced cases per run had zero
  network syscalls and no writable opens except `/dev/null`; native-canary positive
  controls, buffered crash/cancel/deadline suppression, real SIGINT, recovery,
  reaping and unchanged inputs passed. Raw diagnostics/traces stayed in RAM.
- Independent TCP control connected normally to 1.1.1.1:443; the namespace control
  failed with errno 101, only loopback and zero IPv4 routes. This is not a full
  IPv4/IPv6/DNS/inherited-resource production escape matrix.
- Real worker on silence still returned `I'm not sure if I can do it.` with exit
  0 and empty stderr. The negative acceptance result is deliberately retained.
- Full acquisition script passed in a blocked namespace using cached bytes,
  no-op curl and real tar/SHA256: six pre-/four post-extraction hashes. Four
  function-level probes rejected missing/corrupt required files and missing
  pre-/post-extraction manifest entries. This does not test real transport/retries,
  HTTP failures or independent publisher provenance.

## Remaining gates and delivery

No physical Mac/Apple Silicon run, speech gate, validated vocabulary rejection,
production fail-closed launcher, app/server cancellation/admission, model installer,
bundle relocation, full dependency/license/privacy clearance, held-out human
accuracy or five-minute performance acceptance is established. Continue those
workstreams under their own ownership; none blocks preserving this evidence.

## Publication review, 2026-10-28

The actual six-lens review-suite inspected the complete branch additions against
fetched `origin/main`, including all 35 then-untracked files. It returned five
warnings, zero critical findings; deployment risk was low conditional on the
nonproduction/disposable-destination boundary. Its full report and the actual
resolve-review plan/diary remain local and ignored under `.agentic/`.

Four ship-gate observations were explicitly retained as intentional scope or
environment limitations: no independent local native gate; preserved native/build
supply-chain boundaries; explicit acquisition I/O; synthetic reproduction I/O.
They were not disproven or upgraded into privacy/adoption clearance.

The correctness warning R5 was confirmed with a local controlled CPython
post-spawn/pre-constructor-return interruption: `request` returned cancellation
while a synthetic sleeper child remained alive. The check killed/reaped that
child afterward; a normal-constructor deadline control reaped its child normally.
The review resolution corrects the overbroad documentation claim, preserves exact
source, and records the unresolved startup cleanup defect in
[WORKER.md](WORKER.md#preserved-startup-interruption-defect-review-finding-r5) and
[sanitized evidence](evidence/review-startup-interrupt.txt). This is not a real
native/SIGINT timing run. Historical/source-run evidence was not rewritten.

The owner subsequently authorized gated commit/push/PR and rebase-merge for this
preservation issue. That permission does not authorize workflow dispatch,
deployment, a production server, new dependencies, or inference adoption.
