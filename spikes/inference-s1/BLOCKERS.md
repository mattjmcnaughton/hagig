# Issue #6: bounded risk-retirement checkpoint

2026-10-28; inspected base `fbc7a5f036d5d9a92ae6b30e83d18701086b0c10`.
**Decision: patch/evaluate, not proceed to adoption.** This checkpoint adds bounded
structural and checked singleton-closure vocabulary rejection, not a speech gate
or native-source/binary attestation. The dated continuations below supersede the
historical structural-only status. No dependency/pin changed. Historical evidence
is untouched. Issue #6 is not complete. Source provenance follow-up is in
[PROVENANCE.md](PROVENANCE.md).

## Evidence rechecked locally

Python 3.11 standard-library inspection of `corpus.tsv` and
`evidence/{baseline,observed,blocked}.jsonl` finds:

| Question | Result | Boundary |
| --- | --- | --- |
| Independent corpus size | 4 term, 4 spoken non-term, 1 digital silence | Synthetic, not the owner's 10+10 human corpus |
| Paired experiment structure | Each run has 36 decodes: 9 inputs × 2 modes × 2 passes | Repetition is not additional independent fixtures |
| Silence false acceptance using nonempty text as acceptance | 4/4 decodes per run; 12/12 across runs | One unique silent fixture, not a population error-rate estimate |
| Spoken non-term exact reference match | 16/16 decodes per run | Four unique spoken controls; does not establish general non-regression |
| Stability | Same text for each input/mode across both passes and all three runs | Historical files reanalysed locally; native inference was not rerun |
| Background noise, quiet speech, short commands | Not represented as designated conditions | False acceptance/rejection for these conditions is unmeasured |

The historical term results remain mixed: Hagig improves, Parakeet changes case,
Ghostty and sherpa-onnx remain wrong. Case-insensitive intended-term recovery is
1/4 unboosted versus 2/4 boosted (see `FINDINGS.md`). Do not discard silence or
mistakes, count repeated decodes as independent observations, or relabel ordinary
multiword prompts as short-command/quiet-speech evidence.

## Structural vocabulary repair; tokenizer-aware rejection remains a blocker

At the base, both entry points trim text and replace newline with `/`, without
validating before native stream construction. The historical warning case in
`evidence/worker-observed.jsonl` exits **0** with nonempty stdout and six discarded
stderr writes. Containing that warning does not reject a malformed vocabulary.
`verify_worker.py` now expects rejection of the structural canary. The historical
native-warning positive control remains in the preserved evidence, and was also
reproduced using the unchanged base worker locally; no bypass was added to the
candidate worker. Crash-after-result checks now use valid vocabulary.

Implemented spike line-file grammar (not a new product TOML policy):

1. Shared `src/vocabulary.rs` runs before model preflight/recognizer construction
   in both entry points. Read errors are `vocabulary_unreadable`; invalid UTF-8 or
   syntax returns `vocabulary_invalid`, without offending values/native errors.
2. Empty file explicitly selects unboosted streams. Nonempty files contain one
   term per LF or CRLF line; a final newline is optional. Duplicates and spelling
   are preserved, never normalized. Terms may contain single internal ASCII spaces.
3. Reject blank entries, leading/trailing/repeated spaces, other whitespace,
   control/NUL characters, `/` (native stream delimiter), `:` (native score syntax),
   over 256 terms or over 128 UTF-8 bytes per term. No custom scores in this spike.
4. Nonwhitespace Unicode remains syntax-valid, **not certified representable**.
   An emoji control is accepted by both legacy and candidate native paths without
   a warning. Pinned simple-sentencepiece can emit `<unk>` and the evaluated token
   table contains `<unk>`: absence of warnings is not proof of useful encoding.

Five unit tests were run red/green against the old trim/replace behavior (three
initial failures). The byte-identical CLI harness failed against the base binaries
on expected error code, then passed against the candidate: 16 invalid and five
valid vocabularies across both entry points, with missing model/audio paths to
check validation order and empty stdout/content-free errors. This is /build
regression verification, not an approved /prove capture or native privacy audit.

Eight additional diagnostic decodes/checks used three-second digital silence,
base/candidate × malformed/empty/valid-CRLF/unsupported-symbol, under `unshare -Urn`.
Base malformed vocabulary succeeded, leaked its canary to native stderr, and
produced nonempty text; candidate malformed vocabulary exited 1 with stable error,
no text/warning. All six other cases returned nonempty text, preserving the silence
failure and unsupported-token uncertainty. No transcript/raw diagnostic was saved.
No speech-gate, general skip detector, accuracy or performance claim follows.

## Speech-gate decision and approved capture still needed

There is no approved speech-gate implementation/dependency or calibrated threshold.
Do not add an energy cutoff, string blacklist, decoder knob sweep, or new VAD to
make synthetic silence pass: quiet human speech and brief commands are necessary
positive controls. Nonempty ASR output is not evidence speech occurred.

A proposed capture matrix, **not permission to execute or retain recordings**:

| Inputs | Paired measurement | Required outcome/report |
| --- | --- | --- |
| Existing digital silence; explicitly supplied room/keyboard/fan noise | Boosted and unboosted; same gate configuration | All false acceptances, including hallucinated ordinary text |
| Explicitly supplied quiet speech and short commands | Boosted and unboosted; independent references | Every rejection, empty/wrong output, missed term, false insertion, ordinary-word change |
| At least 10 human term clips + 10 human non-term clips, held out | Same decoder/assets; order-balanced pairs | Per-clip results, not aggregate-only success; owner usability judgment |
| 20 warm 15–30-second prompts and separate five-minute input | Same pinned candidate on physical M4/48 GB | All timings/failures, median/p95/max, memory, cold-start and delivery separately |

Owner approval of the concrete capture plan, fixtures/retention, and any new
speech/audio tool is required. Synthetic Linux does not replace physical-Mac
accuracy/usefulness/performance or native privacy acceptance. No new captures
were made for human acceptance. Local synthetic diagnostic checks above do not
replace that capture plan or establish speech/no-speech performance.

## Provenance, licenses, and privacy remain separate gates

Existing pins are unchanged: sherpa-onnx `af2d8d81dbfa61c4cea4c568da78f3982edca005`,
native v2.0.1, int8 export `1ab9323565ddb038682214b292f588070a538ce2`,
NVIDIA tokenizer origin `ae9ad07059c7c739ffaf932226a8fe64ae2620b0`.
`acquire.sh`, `SHA256SUMS`, and `evidence/provenance.json` identify evaluated
artifacts; this checkpoint downloaded and checked them against the retained
manifest, without independently attesting publisher/native build provenance.

Local TOML parsing finds **144 lockfile package records**: 141 registry, 2 pinned
Git, and the local spike. None has a lockfile license field; a lockfile is not a notice
bundle, SBOM, enabled-feature graph, or license clearance. sherpa-onnx-sys lists
`bzip2 0.4.4`, `tar`, `ureq`, `zip`. The locked `zip 9.1.2` graph lists `nix`;
`xattr 1.6.1` lists `rustix`. These are preserved transitive entries, not newly
added direct OS dependencies or proof both compile into the runtime. Review the
actual target/build feature graph before approval; do not delete lockfile entries
to hide this review obligation. Follow-up Cargo metadata and Linux tree inspection
are recorded in PROVENANCE.md; native binary/source equivalence remains unproven.

The existing review records Apache-2.0 for sherpa-onnx and CC-BY-4.0 for both model
cards. Redistribution still needs actual license texts/notices and attribution,
conversion/quantization provenance, the exact ORT/native transitive inventory,
and binary/source/build correspondence. Publisher hashes do not prove those.
There is no new full-stack source/privacy or vulnerability clearance here.

Keep source inspection, observed network/local-write attempts, and execution with
outbound networking blocked as three separate evidence levels. Historical Linux
summaries are not raw traces available for independent reaudit or Mac evidence.
Native descriptor containment does not certify unified logging/crash reports.

## Isolation and recovery boundaries

The current constitution supersedes the original unconditional-enforcement
decision: required is default and fails closed; disabled is a supported explicit
user choice, never fallback. Both retain separate processes, offline operation,
no upload/telemetry/automatic downloads, and content-free diagnostics. Direct
`worker_probe.py` runs are historical synthetic observation controls, not an
implementation of either product launch-mode contract. No launcher was changed.

`unshare -Urn true` succeeded locally and the synthetic diagnostic worker checks
above ran inside that namespace. This is not independent network-denial/attempt
observation. Missing strace prevents repeating the real privacy matrix here. R5's
startup-interruption cleanup defect remains unresolved; see `WORKER.md` and
`evidence/review-startup-interrupt.txt`. No general cancellation guarantee is made.

## Exact next gates

- Owner answered build choices: no checkpoints, yes TDD. No per-step commits.
- Approve the concrete proof capture plan before new acceptance artifacts.
- Supply explicitly consented human fixtures and physical Apple Silicon execution.
- Acquisition of the existing pinned candidate was within the original bounded-
  wave authorization, not a new asset-specific approval. acquire.sh verified all
  ten required asset hashes, and the Rust/native build
  passed with local-library override. eSpeak NG and strace remain absent; no new
  tooling was installed. Missing human controls remain a separate hard gate.
- Complete tokenizer-aware vocabulary rejection, speech-gate verification, native
  provenance/license/privacy review, and both launch-mode checks before adoption.
- Independent six-lens review completed with no executable defect finding; it does
  not clear the blocked full traced verifier or adoption gates. Exact commit-
  message approval remains required before delivery.

## Resumed checkpoint, 2026-11-02 (supersedes tool-availability notes only)

Reused published PR18 `095ed8102ebef43b1a0e56a2af45829b8c85c5a5`; no executable,
harness, model pin, manifest, lockfile or historical evidence changed. Current
finite investigation details and exact asset/license inventory are appended in
[PROVENANCE.md](PROVENANCE.md#resumed-local-inventory-2026-11-02). Decision remains
**patch/evaluate, not adopt**. Issue #6 remains open.

- Recovered nine of ten non-fixture asset-manifest entries match hashes; original
  NVIDIA .nemo, all original spoken WAV fixtures, model license/card documents,
  native notice bundle/build correspondence and macOS assets remain absent.
- Exact table comparison: 1,024 BPE spellings match token prefix; token row 1,025
  is `<blk>`. Shared `<unk>` and warning-free emoji acceptance still do not yield
  tokenizer-aware rejection. Structural validation is not a speech detector.
- strace is now installed. Eighteen bounded exploratory traced worker cases
  (nine each without namespace wrapper and with namespace before tracer) observed
  no network calls or writable opens beyond /dev/null in worker/supervisor scope.
  Corrupt-load diagnostic emission had a real positive control. This is finite
  runtime observation, not complete privacy clearance or product launcher proof.
  Namespace-setup writes found in an earlier broader trace are explicitly retained.
- Digital silence with empty and emoji vocabularies still returns nonempty text
  in all four new normal decodes. No noise/quiet/short-command evidence can be
  inferred from these synthetic zeros, and no gate/threshold was tuned to them.
- Isolated offline native build, five parser tests, fmt/Clippy and 42 unchanged
  vocabulary CLI checks pass after documented recovery/loader setup repairs.
  Full verify_worker.py remains blocked on the original speech fixtures. Its
  expected transcript/assertions were not edited to accept synthetic silence.
- Prior approved structural counterfactual (32/32 candidate vs 0/32 base; 10/10
  accepted-syntax preflight controls per side) remains bounded to that claim.
  No new /prove capture or approval was inferred from exploratory permission.

Concrete next proposals for owner/parent, **not approvals to execute**:

1. Approve a frozen local synthetic failure/privacy capture matrix: existing
   Rust/Python/strace only, missing/corrupt/invalid cases, silence-negative results
   retained, bounded fault seams, memory-only raw diagnostics, sanitized counters.
   Include observer positive control, exact candidate identity and input hashes;
   distinguish observed calls from independent blocked-connectivity controls and
   product-launcher integration. Do not label it the full speech verifier.
2. Preserve separate tokenizer contract design/adoption decision: use exact pinned
   normalization/encoding and detect `<unk>` without arbitrary character bans.
   Native-source/binary correspondence is prerequisite to trusting that result.
3. Owner final Mac session needs consented paired human term/non-term, silence/
   noise and quiet/short-command controls, with independent references and retained
   mistakes. Any new speech gate or audio tooling still requires specific approval.
4. Collect actual model attribution/license documents and conversion/native build
   provenance/notices before redistribution; reconcile #25's independently owned
   security audit without treating it as license clearance. No reacquisition,
   commit, publication, issue closure or inference adoption delegated here.

### Security reconciliation with #25

The independently reviewed [#25 audit](https://github.com/mattjmcnaughton/hagig/issues/25)
identifies two WAV buffer-bounds defects in pinned sherpa source
`af2d8d81dbfa61c4cea4c568da78f3982edca005` (`wave-reader.cc`): non-four-byte-aligned
PCM32/float32 reads and partial multi-channel frame deinterleaving. It also finds
a latent shared-Rust-API native race and unverified native-build input selection.
Source findings are not proof of their presence or exploitability in the recovered
prebuilt libraries. No malformed-WAV native reproduction ran in this checkpoint.
Keep adoption blocked pending source/binary correspondence, parser remediation or
reviewed avoidance, single-thread native ownership and verified build inputs.
Process separation/network isolation alone does not repair native memory safety;
the bounded privacy observations above do not clear these security findings.

### WAV-reader avoidance continuation, 2026-11-03

Both spike entry points now decode supported RIFF/WAVE inputs using bounded safe
Rust and submit normalized PCM through existing `accept_waveform`. Neither calls
`Wave::read` or another native WAV reader. Supported formats match the proposed
CLI set (PCM16/float32, mono/stereo,16/44.1/48kHz, five minutes), not arbitrary
native-reader formats. The spike preserves native first-channel stereo selection
and native inference sample-rate conversion; final canonical CLI conversion is
not established. File and frame limits precede allocation/FFI sample-count use.
Malformed audio is rejected before worker recognizer construction; vocabulary/
model-file-preflight error order remains. See WORKER.md for exact boundaries.

This avoids F1/F2's native WAV entry path in the spike; it does not repair the
prebuilt reader, establish source/binary correspondence, clear other native
parsers/FFI or complete adoption. Silence is still valid audio, not accepted speech.
Initial decoder TDD: three behavioral red tests before implementation, then four
decoder and five existing vocabulary tests pass; offline locked release build,
Clippy and42 CLI vocabulary checks pass. Six independent complete-diff review
lenses completed; the missing original speech verifier remains blocked. Frozen
decoder tests fail under five semantic mutations (frame alignment, normalization,
float range, duration, file cap), and pass after each restoration. A frozen worker
harness rejects four malformed synthetic inputs as `audio_invalid`; moving
recognizer creation before decoding changes the first error to `model_invalid`
and fails its assertion. Restoration passes. These prove mutation necessity, not
original-base attribution or native-reader repair. A three-second synthetic
silence input still decodes to nonempty text with the actual pinned model inside
a Linux network namespace; only the nonempty boolean was retained. Historical
failures and remaining human speech/privacy/license/platform gates stand.

### Tokenizer-aware preflight continuation, 2026-11-03

Both entry points now validate `bpe.vocab` and `tokens.txt` after structural
vocabulary/model-file checks and before native recognizer creation, including
empty/unboosted vocabulary. Each table is limited to 128 KiB before parsing.
The accepted pinned format requires unique UTF-8 pieces, integer i32 rank scores,
canonical positional token IDs, identical ordered BPE/token prefix, unknown at
zero, sole extra blank token, no byte fallback, a boundary singleton and ordinary
piece singleton closure. Broken assumptions return content-free `model_invalid`.

Under those checked assumptions, simple-sentencepiece 0.7's word-prefix/scored
segmentation has a known singleton at every supported scalar boundary. No ordinary
piece covers unsupported scalars; the unknown spelling is not composable from
those singletons. Thus unsupported whole terms return `vocabulary_invalid`
without duplicating dynamic programming or banning all non-ASCII text. Spelling,
case, duplicates and normalization remain unchanged; precomposed and combining
forms can differ. This is this pinned format's contract, not generic BPE support
or evidence that a representable term improves transcription.

Thirteen Rust tests and 42 structural plus 54 public tokenizer-preflight checks
pass offline on Linux. Supported worker controls stop at deliberately missing
audio; fake ONNX files never reach native parsing. Twelve read-only actual-table
controls also reach the expected vocabulary/audio errors without decoding.
Frozen tests pass on the candidate, fail claim-specific assertions under separate
scalar-rejection and closure bypasses, and pass after exact restoration. Those
captures establish mutation necessity, not attribution against the original base.
All six independent complete-original-base review lenses completed without a
code-defect finding; intentional synthetic I/O and verification limits retained.

Native code subsequently reopens paths: concurrent replacement remains a TOCTOU
limit. Ordered correspondence is not cryptographic table identity, ONNX dimension
attestation or native-source/binary equivalence. Unresolved #25 F3/F4, original
speech verifier, human/noise/quiet/short-command, privacy/license/provenance and
physical-Mac gates remain blockers. Historical silence hallucinations are not
fixed or discarded. No new dependency, asset acquisition or speech heuristic.
