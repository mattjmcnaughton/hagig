# S1 findings: Rust + Parakeet TDT vocabulary feasibility

Decision: **continue evaluation, do not adopt yet.** A real Linux Rust experiment
establishes the binding/asset/boosting path. It does not establish the product
acceptance gates. The decisive negative result is hallucinated text on silence.
Native diagnostic leakage and binary/transitive provenance remain adoption gates.

## What ran

- 2026-10-27 UTC (2026-10-26 America/New_York), Debian 12 Linux x86-64 orb,
  kernel 6.1.158, 2 logical Xeon CPUs @ 2.60 GHz, 3.8 GiB RAM, no swap/GPU.
- Rust 1.90.0 release build. sherpa-onnx **v2.0.1**, source and Rust bindings
  pinned to `af2d8d81dbfa61c4cea4c568da78f3982edca005`.
  Prebuilt Linux shared no-TTS library; loaded ONNX Runtime reports **1.28.2**.
- Candidate int8 ONNX export from
  [csukuangfj](https://huggingface.co/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8/tree/1ab9323565ddb038682214b292f588070a538ce2),
  with original tokenizer from
  [NVIDIA](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2/tree/ae9ad07059c7c739ffaf932226a8fe64ae2620b0).
  Exact revisions, URLs, and SHA-256s are retained, not floating `main` assets.
- CPU provider, 2 threads, modified beam search, 4 active paths, hotword score
  1.5, no LM, debug false. Explicit experiment choices, **not tuned defaults**.
- Four synthetic term-bearing clips, four spoken non-vocabulary controls, one
  three-second digital-silence control. Spoken clips span 2.471–3.668 seconds.
  Each decoded boosted/unboosted twice with one shared recognizer; second pass
  reverses order. Separate untraced, traced, and blocked-network runs: **108
  decodes total**, all returning results. These are 9 unique fixtures, not 108
  independent accuracy samples. No owner recordings or remote speech service.

## Actual Rust and TDT boosting path

All source references below refer to the pinned sherpa-onnx revision above.
Prefix paths with `sherpa-onnx/` except where otherwise noted.

1. `rust/sherpa-onnx/src/offline_asr.rs:452–478,557–568,690–715`
   exposes transducer graphs, tokens, `model_type`, `modeling_unit`, `bpe_vocab`,
   modified beam search, beam width, score, and `create_stream_with_hotwords`.
   The safe wrapper invokes the C API; **no binding patch/C bridge was needed**.
2. `c-api/c-api.cc:703–759` validates configuration and constructs the recognizer;
   per-stream hotwords reach the C++ `CreateStream(hotwords)` overload.
3. `csrc/offline-recognizer-impl.cc:294–303` routes `nemo_transducer` to
   `OfflineRecognizerTransducerNeMoImpl`, not the generic transducer decoder.
   `csrc/offline-transducer-nemo-model.cc:224–275` recognizes TDT from exported
   metadata, including the URL and duration-output shape. Setting `model_type`
   explicitly also avoids the model-detection load path.
4. `csrc/offline-recognizer-transducer-nemo-impl.h:55–68,118–152` builds the scored
   BPE encoder and encodes slash-delimited per-stream phrases into a context
   graph. `csrc/utils.cc:104–208` maps encoded pieces through `tokens.txt`.
5. `csrc/offline-transducer-modified-beam-search-nemo-decoder.cc:108–137,246–299,349–391`
   consumes the stream graph, handles token/duration logits and frame advances,
   adds context scores to nonblank candidates, and finalizes partial matches.
   This is genuine decoder biasing, not post-transcription text replacement.
   Greedy search does not run this contextual-biasing path.

### Required assets

| Runtime asset | Bytes | Purpose |
| --- | ---: | --- |
| encoder.int8.onnx | 652,184,296 | Acoustic encoder |
| decoder.int8.onnx | 7,257,753 | Prediction network |
| joiner.int8.onnx | 1,739,080 | Token/duration output |
| tokens.txt | 9,384 | Recognition symbols/IDs, 1,025 entries including blank |
| bpe.vocab | 10,393 | 1,024 tokenizer pieces with original merge scores |

The published int8 export **omits bpe.vocab**. This spike extracts the original
`a4715c7f6b2d4c2bb709306073d0c0a4_tokenizer.vocab` directly from the pinned NVIDIA
`.nemo` archive; all 1,024 pieces match `tokens.txt` in order, excluding the final
blank. The `.nemo` archive and binary SentencePiece model are not needed at
inference time. No scores were synthesized from token IDs. Upstream
`scripts/nemo/generate_bpe_vocab.py` confirms scored pieces are the intended
asset; extracting the shipped vocabulary avoids installing NeMo/PyTorch.

## Measured results

Untraced baseline (`evidence/baseline.jsonl` and `baseline.time`):

| Measurement | Result |
| --- | ---: |
| Fresh-process recognizer construction | 2.789 s |
| First decode, unboosted Hagig | 0.435 s |
| Construction + first decode | 3.224 s |
| Subsequent unboosted decode median / maximum (17 samples) | 0.410 / 0.508 s |
| Boosted decode median / maximum (18 samples) | 0.422 / 0.515 s |
| Whole process, load + 36 decodes | 17.89 s |
| Process peak RSS (GNU time) | 857,392 KiB ≈ 837.3 MiB |

"Cold" means a new recognizer/process, **not flushed filesystem caches**.
Decode timing includes stream creation, hotword encoding when applicable,
feature extraction, inference, and result retrieval; excludes WAV file reading,
model load, IPC, microphone release, and delivery. Steady-state RSS was not
sampled separately. Traced run loads were 2.812 s and 2.494 s (blocked); do not
mix those timings into the untraced summary.

Both passes and all three runs produced identical transcripts per mode:

| Fixture | Unboosted | Boosted |
| --- | --- | --- |
| Hagig | Open **Haji** and transcribe the next instruction. | Open **Hagig** and transcribe the next instruction. |
| Ghostty | Run the command in **Ghost T** without pressing enter. | Same; still misses Ghostty |
| sherpa-onnx | use **sharponics** for local speech recognition. | Use **sherponics** for local speech recognition; still wrong |
| Parakeet | Compare **parakeet** with the current speech model. | Compare **Parakeet** with the current speech model. |
| Four spoken controls | Match their independent references | Identical to unboosted, including ordinary "amp" |
| Digital silence | I'm not sure if I can do **this**. | I'm not sure if I can do **it**. |

Case-insensitive intended-term recovery improves from **1/4 to 2/4**; the
Parakeet change is casing only. Two terms remain missed. No new vocabulary-term
insertions or ordinary-word changes were observed in the four spoken controls.
That tiny result is **not** evidence of "no material regression" in general.
Silence fails in both modes, with different hallucinated ordinary text. A future
speech/no-speech gate must precede delivery; a nonempty ASR string is insufficient.
No score sweep, corpus expansion, alternate model, or silence heuristic was added.

## Privacy: three different evidence levels

### 1. Dependency source inspection (partial, not clearance)

Intent: local CPU inference on sensitive audio/vocabulary eventually; no runtime
telemetry, uploads, recovery downloads, or content history allowed. No server or
authentication surface is exercised. Static inspection was read-only, scoped to
Rust offline ASR/WAV bindings and sys build script, C API recognizer functions,
C++ recognizer dispatch/config, NeMo model/decoder, hotword utilities, file
utilities, session/provider setup, and relevant CMake dependency declarations.
Tests/other model implementations were search context, not adopted features.

- No active HTTP/socket/download operation found in the inspected local NeMo
  inference path. It opens named local graph/tokenizer files and ORT sessions
  (`csrc/offline-transducer-nemo-model.cc:33–52`). **Exfiltration verdict remains
  indeterminate for the entire transitive stack**, not "no outbound channels".
- **Adoption blocker: native error diagnostics can disclose sensitive values.**
  `csrc/utils.cc:66–70,128–132` logs token/phrase contents on invalid hotwords;
  `csrc/offline-recognizer-transducer-nemo-impl.h:124–127` can log the entire
  hotword string. `debug=false` does not disable these error paths. Corrupt-model
  runtime evidence below also shows filename leakage. Contain/suppress native
  stderr inside the future isolated worker and return only stable error codes;
  do not forward native diagnostics to application logs. No private fixtures
  were run through these paths.
- Keep `debug=false`; do not set a provider config with `ProfilingFilePrefix`
  (`csrc/session.cc:251–255` enables persistent ORT profiling). CPU provider avoids
  optional accelerator cache/configuration paths; none were audited for macOS.
- Build-time network is separate: `rust/sherpa-onnx-sys/build.rs:115–125,203–215`
  downloads native release binaries unless `SHERPA_ONNX_LIB_DIR` or an archive
  override is supplied. This default path does not verify a cryptographic
  publisher checksum. We supply local libraries and retain measured hashes.
- Rust runtime direct dependencies are sys, serde, serde_json; sys build-time
  dependencies include bzip2, tar, ureq, zip. `Cargo.lock` fixes the resolution.
  Native declarations include ORT 1.28.2, simple-sentencepiece 0.7,
  kaldi-native-fbank 1.22.4, and their further dependencies. Their full source,
  build flags/SBOM, binary/source equivalence, and vulnerability status were
  **not** verified. No external vulnerability scanner was run. Prebuilt binaries
  are a trust boundary, not reproducible native-build evidence.

### 2. Observed network/write behavior

`strace -f -yy -e trace=%network,%file,write,writev,pwrite64` followed the inference
process and threads, with network available. In the successful run, **zero
network syscalls**, **zero writable file opens**, and **37 writes, all to stdout**
(one load record and 36 synthetic results) were observed. Native stderr was
empty. Read-only opens included model/tokenizer/WAV data, dynamic libraries,
CPU/system metadata, and `/proc/self/maps`. The shell's deliberate evidence-file
redirection is outside the traced child's file-open activity.

Missing model: Rust preflight exits 1 before calling the native library. Corrupt
encoder: native constructor fails, returns None through Rust, exits 1; native
stderr includes `.agentic/inference/corrupt/encoder.int8.onnx`. Both failure
traces have zero network syscalls/writable opens, and only stderr writes.
No fixture/model hash changed. These observations cover selected syscalls and
finite CPU scenarios, not all possible OS persistence or dependency behavior.

### 3. Operation with outbound networking blocked

Repeated all 36 decodes inside `unshare -Urn`. Separate direct-connect probe to
1.1.1.1:443 fails immediately (curl exit 7; no route). All outputs match the
network-available baseline. The blocked inference trace also has zero network
syscalls/writable opens and only 37 stdout writes. Missing/corrupt model checks
again exit 1 without network attempts. **Offline success is separate from, and
does not replace, the attempted-network observation above.**

## Licensing and acquisition boundaries

- sherpa-onnx and its Rust crates declare Apache-2.0. NVIDIA's pinned model card
  and the int8 export's card metadata declare **CC-BY-4.0**, not Apache-2.0.
  Preserve NVIDIA attribution, the CC-BY-4.0 license link, exporter/source
  provenance and notice of conversion/quantization when distributing model or
  tokenizer assets. The export is third-party converted material, not an
  NVIDIA-published ONNX artifact. Source hashes do not establish licensing of
  all training data or provide legal clearance.
- The prebuilt native archive contains libraries, not a complete license/SBOM
  bundle. Collect ORT and other transitive notices/license texts and verify
  exact native provenance before bundling; the top-level Apache notice is not
  enough. eSpeak/FFmpeg are fixture-generation tools only, not proposed product
  dependencies. No audio/model/native binaries are added to this repository.
- Model/tokenizer download is an explicit spike action; this is not an adopted
  application model manifest or an automatic recovery/install mechanism.

## Exit boundary and next two recommended tickets

Established: Rust can run the actual quantized candidate and reach real TDT
contextual biasing on Linux within this orb's RAM; at least one intended spelling
improves; finite CPU scenarios run without observed networking or internal file
writes and also work with outbound networking blocked. Source/build/assets and
negative results are reproducible from this directory.

Unresolved: representative human accuracy/correction burden; 10+10 AC8 corpus;
20 warm 15–30-second AC6 samples; five-minute memory/time; speech gating;
Apple Silicon native build/latency; worker lifecycle/cancellation; relocatable
bundle loading; focus safety; full native/transitive privacy and license gate.
Linux results prove **none** of M4/48 GB/macOS latency, packaging, focus safety,
or general runtime privacy. Stop this bounded spike here rather than implementing
the application, tuning synthetic audio, or claiming S1/AC6–AC13 complete.

1. **S1b: establish a safe inference acceptance path on the M4.** Depends on Mac
   execution access and these candidate pins. Scope: a minimal isolated Rust
   file-inference worker/harness (not the server/app), contained native stderr,
   explicit local asset verification, and speech/no-speech rejection. Verify
   missing/corrupt assets, silence/ambient noise versus quiet speech, worker
   failure, 10 term + 10 non-term human fixtures supplied explicitly for testing,
   20 warm 15–30 s samples and a five-minute bound. Record all outputs/timings,
   peak memory, build/native pins and separate privacy evidence. AC6/8/9/10/11;
   constitution 1/2/5/6. Exit: adopt with evidence, patch narrowly, or reject;
   do not silently weaken silence/privacy/performance gates.
2. **S2: implement only the native intended-input identity/paste safety probe.**
   Independent of S1b once Mac access exists; no inference/model dependency.
   Exercise Ghostty panes/tabs, Chrome/Amp tabs/inputs, focus races and permission
   failures with a fixed nonpersonal string; no microphone/server framework.
   Establish whether identity is granular enough, verify no focus theft/Enter,
   cancellation-before-delivery and current-device-only clipboard API behavior.
   Record actual OS and accessibility evidence. AC1–5; constitution 3/4/7.
   Exit per destination: verified delivery feasible, or request owner acceptance
   of safe fallback-only scope. A second Apple device remains needed for AC5's
   observational check. Final relocatable packaging/privacy S3 follows candidate
   selection; it is not established by either ticket.
