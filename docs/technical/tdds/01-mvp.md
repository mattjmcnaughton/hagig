# Hagig private-alpha technical design

Status: proposed implementation design; no native implementation or spike results
exist yet. Swift/Rust ownership, worker isolation, local processing, and safe
delivery are agreed boundaries. Concrete protocols, paths, limits, CLI syntax,
and timeout defaults below are proposals to implement or revise with evidence.

Read the [constitution](../../CONSTITUTION.md) and [MVP PRD](../../product/prds/01-mvp.md) first. This
document does not certify dependency privacy or model performance.

## 1. Architecture and ownership

```text
Swift macOS app ── Unix-domain socket ──┐
                                      ├── Rust server ── private pipes ── Rust worker
Rust CLI ──────── Unix-domain socket ──┘                                  │
                                                                  sherpa-onnx
                                                                  Parakeet TDT
```

- **Swift app:** AppKit menu-bar lifecycle, global shortcut, permissions, microphone
  capture/conversion, intended-destination identity, final delivery, and fallback UI.
- **Rust server:** single-request admission, authoritative backend request state,
  configuration/model validation, audio buffering, worker supervision, and cancellation.
- **Rust worker:** native inference, plus any adopted native audio decoding. Native crashes remain
  outside the server and app. No networking, microphone, clipboard, or UI ownership.
- **Rust CLI:** explicit model installation, file transcription, status, and stop.
  It is a sibling client, not an automation interface into the Swift app.

Start with one Rust package containing shared protocol/state/configuration code
and separate executable entry points. Do not create a crate per process merely
because there are several executables. The Swift app lives in `clients/macos/`.
The package layout and exact build commands should be established with the first
validated scaffold, not invented as working commands in the README now.

Keep portable backend code free of AppKit, Accessibility, and macOS permission
logic. This preserves a credible Linux path without a Linux desktop implementation.

## 2. Native inference adoption gate

First candidate: sherpa-onnx with NVIDIA Parakeet TDT 0.6B v2, using modified beam
search and its contextual-biasing/hotword support. This is an evaluation target,
not an adopted, benchmarked, or privacy-cleared dependency.

Prior source inspection used sherpa-onnx revision
`88204440c2ad19158fe77dbf470bb1fe7fdee613`. That revision is a research reference,
not the final dependency pin. Do not assume current Rust bindings expose every
required decoder/tokenizer option. Prefer the existing binding; if it is incomplete,
evaluate the smallest C-API bridge or upstream binding change before introducing
another backend architecture.

The adoption spike must establish:

1. A reproducible Apple Silicon build and portable Linux inference experiment.
2. Actual Parakeet decoding from Rust with vocabulary boosting, necessary token/BPE
   assets, and paired non-vocabulary controls.
3. Accuracy, release-to-text latency, cold load time, resident/peak memory, and
   behavior up to the five-minute input cap.
4. Native dynamic-library loading from an app bundle without checkout paths.
5. Source, runtime-network/write, and blocked-network evidence as separate records.

Pin the selected library, bindings, native dependencies, model revision, assets,
licenses, download sources, and checksums in a tracked manifest before adoption.
Do not invent artifact URLs or hashes before identifying the actual artifacts.
If conversion is necessary, pin the conversion inputs/toolchain as well.

No decoder beam width, hotword score, thread count, quantization, or acceleration
provider is settled here. Measure the candidate defaults before adding knobs.
Do not claim Core ML/Neural Engine acceleration without observing the actual path.

## 3. Configuration and filesystem locations

Use TOML only for the alpha. YAML in the prototype was an alternative representation,
not another format to implement. Proposed schema:

```toml
# $XDG_CONFIG_HOME/hagig/config.toml
# Default: ~/.config/hagig/config.toml, including on macOS.
[shortcut]
hold = "ctrl+shift+space" # Example; validate against the owner's shortcuts.

[model]
id = "parakeet-tdt-0.6b-v2" # Candidate alias resolved by the pinned manifest.

[vocabulary]
terms = ["Hagig", "Ghostty", "sherpa-onnx", "Parakeet", "Amp"]
```

The Rust server parses and validates configuration; Swift receives only its needed
settings through the protocol, not the vocabulary. Reject unknown keys, unsupported
model aliases, invalid shortcuts, and invalid types with field names and error
codes, not raw offending values. Read configuration at server startup. For the
alpha, apply edits by quitting the app, running `hagig stop`, and relaunching the
app. No file watcher or live reload command is needed; an active request's settings
never change. Invalid startup configuration returns an actionable error instead
of silently falling back to different settings.

Shortcut syntax and supported key combinations need one documented grammar and
shared fixtures between Rust validation and Swift interpretation. The example
binding is not an accepted conflict-free default on the owner's machine.

| Purpose | Proposed location/policy |
| --- | --- |
| Configuration | `$XDG_CONFIG_HOME/hagig/config.toml`, default `~/.config/hagig/config.toml` |
| Models | `$XDG_DATA_HOME/hagig/models/<manifest-id>/`, default `~/.local/share/hagig/models/<manifest-id>/` |
| Runtime socket/lock | Private per-user runtime directory; see below |
| Recordings/transcripts | In memory only; no history directory or temporary audio files |
| Logs | Content-free stderr by default; no persistent app log file by default |

Prefer a valid, owner-only `$XDG_RUNTIME_DIR/hagig/`. On macOS without it, use the
OS-provided per-user temporary directory and a `hagig/` child. On Linux without it,
use an owner-validated `/tmp/hagig-<uid>/` directory. Require owner-only directory
permissions (0700), socket permissions (0600), no symlink substitution, and the
expected owner. Fail closed on an unsafe preexisting path rather than chmod or
delete another owner's object. Check Unix-socket path length before binding.

The private-alpha threat boundary is other OS users and accidental exposure, not
a malicious process already running as the same user. File permissions are not
authentication against that process. Do not listen on TCP.

## 4. Installation and model acquisition

Proposed command: `hagig model install <manifest-id>`. It is the explicit network
action; starting the app or a transcription never downloads or repairs a model.
Download into a model-only staging directory, enforce manifest checksums, then
atomically publish the validated installation. Reject traversal/symlink entries
if unpacking archives. A failed install must not replace a valid installation.

Normal loading resolves only installed manifest entries, validates the expected
assets, and returns `model_missing` or `model_invalid` without attempting recovery
networking. A versioned installation must not change beneath a warm worker.

Bundle the app, server, worker, CLI, and required native libraries together.
Resolve helper paths relative to the installed bundle, not ambient PATH or the
developer checkout. Model assets remain separate to make downloads explicit.
Document the CLI invocation/path during alpha installation; no Homebrew cask is
required. No login service or automatic updates for the alpha.

The packaging spike must test relocation, architecture compatibility, native
loader paths, required local signing, permission stability across rebuilds, and
installation without developer runtimes. Public notarization remains deferred.

## 5. Server startup and lifecycle

On app launch or a CLI operation needing the server, try the private socket. If
absent, spawn the bundled server and wait for readiness with a bounded deadline.
Use an OS advisory lock held for the server's lifetime to arbitrate simultaneous
startup. Only the lock holder may remove an owner-validated stale socket and bind
a new one. A second startup must attach to the winner, not launch another worker.
Never kill a PID just because it appears in a stale file.

Proposed startup/connect deadline: 5 seconds. This covers server readiness, not
model loading. Return a clear startup error on timeout; no unbounded spawn loop.
Version mismatch returns an explicit incompatibility error instead of restarting
or killing an active server from another installation.

The server is per-user and on demand. It remains alive after clients exit. The
worker loads on first transcription, stays warm with its validated configuration,
and has no idle eviction in the alpha. This intentionally retains model memory;
`hagig stop` is the release mechanism. Logout/OS process termination ends the
session; the server needs no login registration or durable recovery state.

`hagig stop` does not start a missing server. It stops admission, invalidates active
work, requests worker exit, escalates if necessary, cleans up its owned runtime
socket, and exits. Closing a non-owning client must not cancel another client's work.

## 6. Client protocol and request ownership

Use a versioned framed protocol over a Unix-domain stream. Proposed v1 frame:

```text
1 byte kind | 4 bytes unsigned big-endian payload length | payload
kind 1: UTF-8 JSON control message (maximum 64 KiB)
kind 2: binary PCM audio chunk (maximum 256 KiB)
```

Control messages include `version`, `type`, and a client-generated `request_id`
where applicable. Audio frames belong to the connection's one admitted request;
they cannot route audio to another connection's request. Decode lengths before
allocation; reject oversized frames, malformed controls, invalid sample alignment,
unexpected ordering, and audio exceeding the recording limit. Close a malformed
connection and cancel only its owned request. Never echo a rejected frame in logs.

Proposed controls:

| Message | Contract |
| --- | --- |
| `hello` / `hello_ok` | Negotiate protocol version; report display model, shortcut, capture format and limits; no vocabulary |
| `begin` / `accepted` | Reserve the single active slot before app recording or CLI audio submission; freeze configuration generation and model identity |
| `end_audio` | Finish PCM submission and start inference |
| `cancel` / `cancelled` | Cancel the connection's matching request; idempotent acknowledgment for an already terminal request |
| `result` | One final transcript for the matching live request; empty result does not authorize delivery |
| `error` | Stable code and safe message; examples: busy, model_missing, model_invalid, invalid_audio, worker_failed, deadline_exceeded |
| `status` | Version, idle/busy/loading state and model identity only, not content or vocabulary |
| `stop` | Invalidate work and shut down; no result delivery after stop wins |

For the alpha, use canonical mono 16 kHz float32 little-endian PCM on the wire.
Swift converts microphone audio; the CLI decodes supported WAV input into the same
format using portable code, subject to dependency review. If decoding requires
native unsafe code, move that decoding into an isolated helper/worker rather than
loading it into the server. Do not pass arbitrary filesystem paths to the server.

Reserve the slot before capture to avoid five minutes of recording followed by
busy rejection. Keep audio in the Swift process until release, then submit bounded
chunks. The server buffers the complete request in memory, then forwards it over
private worker pipes using the same bounded framing. Five minutes of canonical
PCM is 19,200,000 bytes per full buffer; peak memory includes multiple buffers and
the model, and must be measured. No claim of zero-copy transport is made.

Proposed resource caps: five minutes total audio, control frame limit above,
256 vocabulary terms of at most 128 UTF-8 bytes each, and final result payload
within the control-frame limit. Fail explicitly if a result exceeds the cap; never
truncate and deliver misleading text. Revisit caps with representative fixtures.

Client connection loss cancels its reservation/inference. Proposed reservation
deadline is 330 seconds through completion of audio upload; model/inference then
has a separate 120-second hard deadline, to be checked against five-minute inputs
in the spike. These are failure bounds, not acceptable interactive latency.

## 7. State machine and cancellation

Server request lifecycle:

```text
Idle -> Reserved/receiving -> Loading worker -> Transcribing -> Result returned -> Idle
                    any active state -> Cancelled/Failed -> Idle
```

Only one admitted request exists, including its recording reservation. An invalid
or busy request must not disturb it. Each terminal transition releases buffers
and the active slot exactly once. Worker responses include a server-assigned
generation as well as the request identity; a stale worker response cannot match
a new request that reuses a client ID.

Swift additionally owns local states: ready, awaiting admission, recording,
uploading/transcribing, result pending, fallback, delivery initiated, and cancelled.
The server cannot enforce final UI delivery; **both sides must invalidate work**.

- On Escape, first invalidate the local generation and discard pending display/
  delivery work, then send cancellation. Do not wait for an acknowledgment before
  preventing delivery.
- Serialize cancel, result handling, focus checks, and delivery initiation through
  the app's main-actor state. Recheck the live generation immediately before any
  display, clipboard write, or paste request.
- Shortcut release/cancellation before admission completes must not later start
  microphone capture. Cancel a subsequently accepted reservation.
- Server cancellation invalidates the request before stopping native computation.
  If inference cannot be interrupted safely, terminate the worker; never call
  native inference concurrently with teardown inside the same process.
- Proposed escalation: request exit, wait up to 1 second, terminate, then kill after
  another 1 second if needed. Reap the child before admitting work to its successor.
- A worker crash fails that request. Do not retry the recording automatically;
  restart lazily for the next user request and avoid an automatic crash loop.

Cancellation that wins before delivery initiation prevents delivery. Cancellation
after a clipboard write or paste request cannot undo that effect; communicate
the boundary accurately. Tests must exercise both orderings rather than promise
an impossible rollback.

The fallback transcript is app-owned memory after server completion. Starting a
new recording discards any previous fallback; do not accumulate a transcript list.

## 8. macOS capture, focus verification, and delivery

Use native microphone capture and sample-rate conversion. Check permissions before
recording, handle device loss/interruption explicitly, and never persist captured
audio. An interruption cancels capture rather than delivering an unexplained
partial prompt. The five-minute cap intentionally produces a partial recording;
it is a separate, documented completion path. Warn 15 seconds before the cap as
the proposed PRD default. Release and cap firing must converge on one completion.

Use Accessibility/native application identity APIs to snapshot the intended app,
window, and focused editable element at recording start. Snapshot only identity
and capability metadata needed for delivery, not destination text or screen
contents. App PID alone is insufficient. Exclude password/secure inputs.

Before automatic delivery, verify the same live input/window/app identity and
observe focus changes throughout the session. Once destination identity changes,
is lost, or cannot distinguish a relevant tab/pane/input transition, use fallback
even if the user later returns. Do not silently treat a terminal-wide accessibility
element as proof of a particular pane. Do not activate the destination application.

**This is a blocking feasibility question, not a proven API solution.** Ghostty
may not expose enough input identity, and browser editors differ. The native spike
must test actual pane/tab/input changes and the focus race immediately around
clipboard/paste initiation. If macOS cannot support sufficiently safe automatic
delivery for a target, ship safe fallback there only with explicit owner acceptance
of that limitation; do not quietly relax the constitution or AC1/AC2.

After final identity/generation validation, write the general pasteboard using
the current-device-only option and request the ordinary paste action. Never send
Enter. Keep the gap between validation and paste minimal; changing focus races
must be investigated, not dismissed as solved by a single API call. Do not claim
a universal destination acknowledgment.

Explicit Copy uses the same current-device-only pasteboard write but no focus
verification or simulated paste. It follows an intentional click/key activation
on the fallback UI. Once the clipboard write occurs, cancellation cannot undo it.
Do not restore or clear the user's clipboard in the alpha.

Use a nonactivating status surface for routine recording/transcription feedback.
If the UI surface itself changes focus, it invalidates automatic delivery rather
than granting itself a focus-verification exception. Interactive fallback appears
only after automatic delivery has been abandoned. Respect reduced-motion settings,
use native accessibility labels, and show the installed model's display name.

## 9. CLI contract

Proposed alpha commands, not currently executable:

```text
hagig transcribe <audio.wav>
hagig model install <manifest-id>
hagig status
hagig stop
```

Accept PCM WAV at 16-bit integer or 32-bit float, mono/stereo, 16/44.1/48 kHz,
maximum five minutes; convert/resample deterministically. Reject unsupported or
malformed formats without attempting downloads. WAV support and conversion
dependencies must be validated in the inference spike before widening formats.

`transcribe` starts/connects to the server, reserves a request, decodes and submits
canonical audio, prints only the final text plus newline on stdout, and sends
safe diagnostics to stderr. Ctrl-C invalidates the client's request and cancels
it. No microphone, clipboard, or paste operations. Never change the input file.

Proposed exit codes: 0 success, 1 transcription/server failure, 2 usage/configuration
error, 3 busy, 130 interruption. An empty recognized result is success with empty
stdout. `status` reports stopped without starting a server; `stop` on a stopped
server succeeds. Model installation is separate from transcription-server startup.

## 10. Privacy, errors, and diagnostics

Never log transcript, audio, vocabulary terms, raw config, or full IPC messages.
Use stable codes, stage names, durations, versions, and bounded numeric counters.
Do not echo a filename or native error string that may contain sensitive input
without deliberate sanitization. Worker stdout is protocol-only; native diagnostics
must not flow unfiltered into app logs. Inspect whether the library prints hotwords
or tokens and suppress/configure that path before adoption.

Ordinary errors must be actionable without leaking content: permission needed,
model missing/invalid, busy, no speech, worker failed, or deadline exceeded. A result
is not success if decoding failed. No crash dump or diagnostic export is enabled
by default. OS swap/crash services and third-party clipboard/destination retention
are separate boundaries; finite application tests cannot promise secure erasure
or control of all OS-managed storage.

Dependency review must cover native libraries, model loaders, file decoding,
tokenizers, transitive dependencies, install scripts, and any automatic download
path. Explicit installer traffic is distinct from forbidden runtime traffic.
Observe actual network attempts and local writes, not just successful connections.
Test missing/corrupt models with networking both available and blocked.

## 11. Verification strategy

Map implementation tickets to the PRD's AC identifiers. Keep enduring tests at
public interfaces: protocol/client operations, CLI outcomes, and app-visible
delivery effects. Use temporary probes freely for spike evidence; do not retain
tests of private call order or decorative formatting.

| Layer | Evidence |
| --- | --- |
| Portable Rust | Framing/limits, busy admission, startup contention, configuration validation, malformed audio, request-owner disconnect, cancellation/late results, worker crash/deadline recovery, CLI stdout/errors/input preservation |
| Inference integration | Actual pinned model; paired boosted/unboosted fixtures and controls, silence, supported WAV variants, long audio, cold/warm latency and memory |
| macOS build | Swift target and bundled Rust helpers/native library linkage on macOS; Linux success is not a macOS build |
| Physical Mac | Global shortcut, permissions, microphone/device loss, nonactivating feedback, Ghostty/Chrome identity changes, cancel/delivery races, current-device-only clipboard, installation and performance |
| Privacy | Distinct source inspection, observed network/write behavior, blocked-network operation; include failure and recovery paths |

Automated fake-worker tests should intentionally return results after cancellation,
reuse request IDs across generations, crash while active, and stall. At least one
real-worker test must establish recovery after process death. Verify service/process
cleanup, not just returned text. An additional Apple device is needed for the
observational Universal Clipboard check; API inspection alone is not that evidence.

The prototype's browser checks establish only the HTML artifact's behavior.
GitHub macOS build jobs and VMs can help but do not replace physical-Mac acceptance.
Do not assume acceleration availability in a VM.

## 12. Spike-first implementation sequence

This is an ordering proposal, not a created ticket backlog. Bound each spike to
one focused investigation and review the result before expanding it. A proposed
timebox is 1–2 working days per spike once its environment and fixtures are ready.
An exhausted timebox produces findings and a decision request, not an endless
prototype or an unsupported pass. Keep independently useful experimental code only
when its ownership and verification are clear.

| Spike | Question, evidence, and exit decision | Unblocks |
| --- | --- | --- |
| S1: inference and vocabulary | Can Rust run the candidate, improve technical vocabulary without material control regressions, and plausibly meet AC6–AC8? Produce build recipe, exact artifacts, paired outputs, latency/memory and long-input results. Proceed with pins, narrow the binding gap, or propose a different candidate. | Model adoption, worker, audio conversion, performance budgets |
| S2: native destination safety | Can Ghostty and Chrome/Amp expose stable intended-input identity and accept paste without focus theft/submission? Exercise tab/pane/input changes, cancellation races, permissions and clipboard locality. Proceed per target or bring an explicit fallback-only limitation/design change for review. | Capture/delivery shell, permission UX, platform acceptance scope |
| S3: packaging and privacy | Can the chosen native stack run from a relocatable self-contained bundle without forbidden runtime behavior? Produce loader/install evidence plus separate source/network/write/blocked-network findings. Proceed, patch dependencies, or reject adoption. | Distribution layout, dependency lock-in, alpha installation |

S1 and S2 can run independently once Mac execution is available. Begin source
privacy review during S1 rather than after adoption; S3's final native packaging
and runtime evidence depends on the candidate S1 selects. Stop early on a privacy
violation rather than spending the remaining spike budget on speed measurements.

Then implement vertical slices:

1. **Reproducible scaffold:** portable Rust checks plus a buildable minimal Swift
   target and Mac execution instructions. No speculative framework layers.
2. **File to text:** real CLI → server → isolated worker, explicit model install,
   WAV input, one active request, errors and cancellation. AC8–AC13 as applicable.
3. **Hold to safe fallback:** Swift capture → same server → in-memory transcript,
   Copy/Dismiss, state feedback, duration cap and permissions. AC3–AC5, AC9, AC14.
4. **Verified delivery:** enable automatic paste only for spike-validated inputs;
   complete Ghostty/Chrome safety matrix. AC1–AC5.
5. **Daily-use alpha:** bundle installation, warm-path tuning, held-out usefulness
   corpus, privacy/failure evidence, and full acceptance run. AC1–AC14.

Each eventual ticket should name a user-visible or risk-retirement outcome, relevant
ACs/constitutional boundaries, dependencies, bounded scope, verification environment,
and required evidence. Do not organize tickets as isolated Swift/server/CLI silos.
Create external tracker issues only when requested.

## 13. Decisions to review, and evidence still missing

Owner review is requested for the PRD's proposed corpus thresholds and the design's
WAV-only CLI, restart-to-apply configuration, resource caps, warning timing, and hard deadlines.
These are reversible defaults, not new constitutional commitments.

No review can substitute for these still-unverified facts:

- Exact Rust binding coverage and model/tokenizer/native dependency pins.
- Ghostty pane/tab and Chrome input identity fidelity, including delivery races.
- Actual latency, correction burden, memory use, native loading, and privacy behavior.
- Physical-Mac execution path and fixture handling; no live runner was connected
  when planning began.

Resolve technical unknowns through S1–S3. If evidence contradicts an agreed product
or constitutional requirement, document the conflict and obtain an explicit decision;
do not relabel an unsafe or slow implementation as satisfying the requirement.
