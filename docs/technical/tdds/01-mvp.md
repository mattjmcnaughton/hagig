# Hagig private-alpha technical design

Status: copy-only alpha implementation design, not a working alpha. The native
synthetic shell and merged #7 controlled lifecycle/launch code exist; see
[native guidance](../../../clients/macos/AGENTS.md) and
[backend guidance](../../../backend/AGENTS.md) for implemented commands/evidence.
Real transcription, TOML integration, editable review and local `.app` assembly
remain planned. #6/PR18 is a blocked partial candidate, not inference adoption.
Agreed scope is in the PRD; unimplemented protocol/configuration details below
remain proposals unless explicitly identified as settled owner choices.

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

- **Swift app:** AppKit menu-bar Record/Stop lifecycle, permissions, microphone
  capture/conversion, in-memory editor and explicit current-device-only Copy.
- **Rust server:** single-request admission, authoritative backend request state,
  configuration/model validation, audio buffering, worker supervision, and cancellation.
- **Rust worker:** native inference, plus any adopted native audio decoding. Native crashes remain
  outside the server and app. No networking, microphone, clipboard, or UI ownership.
- **Rust CLI:** explicit model installation, file transcription, status, and stop.
  It is a sibling client, not an automation interface into the Swift app.

Start with one Rust package containing shared protocol/state/configuration code
and separate executable entry points. Do not create a crate per process merely
because there are several executables. The Swift app lives in `clients/macos/`.
The scaffold is implemented in `backend/`; use its guidance for current commands.
Complete app build/terminal launch commands belong to #23 once validated; do not
invent them as working instructions now.

Keep portable backend code free of AppKit, Accessibility, and macOS permission
logic. This preserves a credible Linux path without a Linux desktop implementation.

### Inference network-isolation decision

Owner decision, revised 2026-10-28: two explicit modes, `required` and `disabled`.
Default to `required`; omission must not disable enforcement. Users may explicitly
select `disabled` as a supported product mode, not just a development exception.
There is no automatic mode or fallback. Reject unknown mode values rather than
loosening isolation. In required mode, unavailable or failed enforcement refuses
worker startup with an actionable, content-free error. In disabled mode, keep the
separate worker, private pipes, diagnostic containment, and environment/descriptor
hygiene, but do not claim OS-enforced network blocking. Neither mode permits
uploads, telemetry, automatic model downloads, or network-dependent inference.

The boundary remains the inference worker, not the entire app/server/CLI.
Required mode initially uses `sandbox-exec` on macOS. It is deprecated; treat
availability and behavior on supported macOS versions as a validation gate, not
a stable long-term platform guarantee. Disabling isolation is an intentional
configuration choice, never an implicit retry after sandbox setup fails.

The implemented Linux launcher uses separate user/network namespaces.
Unprivileged namespaces may be restricted by the host; enforcement or refusal
evidence for the controlled worker is not real-inference privacy certification
or a claim of portability to every Linux installation.

In required mode, establish isolation before native loading. In both modes, the
worker communicates through private pipes, not the server's Unix socket. Close
unnecessary inherited descriptors and do not pass preconnected network sockets
or network-capable proxies. Explicit model installation remains a separate
operation outside this boundary. A network sandbox alone does not restrict
filesystem access or prove absence of network attempts, diagnostic leakage,
or other privacy violations.

Before adoption, exercise the real worker under the policy: successful inference,
missing/corrupt assets, worker restart, blocked outbound IPv4/IPv6 and DNS paths,
and an independent connectivity control outside the sandbox. Verify required pipe
IPC still works and denied networking cannot escape through inherited resources.
Record the selected mode, policy, OS/tool versions, and observed denials separately
from source inspection. Test required-mode failure without target execution or
automatic fallback on restricted hosts; separately demonstrate explicit disabled
mode can launch there without a network-blocking claim. Disabled-mode success
must not count as required-mode enforcement evidence. Ubuntu support is not
capped at 22.04: on hosts that reject required namespace setup, explicit disabled
mode is the supported path while modern-host enforcement investigation is deferred.
Neither these documents nor workflow definitions establish runtime enforcement.

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
not another format to implement. Proposed schema (not parsed by the scaffold yet):

```toml
# $XDG_CONFIG_HOME/hagig/config.toml
# Default: ~/.config/hagig/config.toml, including on macOS.
[editor]
mode = "standard" # Default. Optional "vim" selects the bounded table in §8.

[model]
id = "parakeet-tdt-0.6b-v2" # Candidate alias resolved by the pinned manifest.

[inference]
network_isolation = "required" # Default. "disabled" is an explicit opt-out.

[vocabulary]
terms = ["Hagig", "Ghostty", "sherpa-onnx", "Parakeet", "Amp"]
```

The Rust server parses and validates configuration; Swift receives only its needed
settings through the protocol, not the vocabulary. Reject unknown keys, unsupported
model aliases, unknown editor modes, and invalid types with field names and error
codes, not raw offending values. Read configuration at server startup. For the
alpha, apply edits by quitting the app, running `hagig stop`, and relaunching the
app. No file watcher or live reload command is needed; an active request's settings
never change. Invalid startup configuration returns an actionable error instead
of silently falling back to different settings.

The proposed `inference.network_isolation` field selects the agreed mode contract
above. Apply it at server/worker startup, not per audio chunk or an untrusted client
request. Report the selected mode in content-free status so explicit opt-out cannot
be mistaken for sandbox enforcement. The scaffold's launcher-mode API can precede
TOML/server integration; documenting this field does not make it executable today.

The settled editor choices are Standard by default and explicit Vim opt-in.
Reject unknown values; no global shortcut field or key-hook permission is needed
in this milestone. Native key routing and the bounded command table are in §8.

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

Local-first plan (#23), not an implemented build/install recipe: build from a
clone and launch the resulting relocatable `.app` from a terminal. The eventual
verified instructions must name prerequisites, exact build command, artifact,
terminal launch command, explicit model install and stop/relaunch procedure.
No `/Applications` placement, Homebrew or public release is required. #24 owns
later distribution; it is not a prerequisite for this source-build workflow.

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
| `hello` / `hello_ok` | Negotiate protocol version; planned app settings include display model, editor mode, capture format and limits; no vocabulary |
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
busy rejection. Keep audio in the Swift process until Stop/cap, then submit bounded
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
uploading/transcribing, review/editing, copy initiated, and cancelled.
The server cannot enforce final UI delivery; **both sides must invalidate work**.

- On Escape/Cancel during capture or transcription, first invalidate the local
  generation and discard pending display/delivery work, then send cancellation.
  Do not wait for an acknowledgment before preventing delivery.
- Serialize cancel, result handling, editor changes and Copy initiation through
  the app's main-actor state. Recheck the live generation immediately before any
  display or clipboard write. Vim review Escape is mode switching, not Cancel.
- Stop/cancellation before admission completes must not later start
  microphone capture. Cancel a subsequently accepted reservation.
- Server cancellation invalidates the request before stopping native computation.
  If inference cannot be interrupted safely, terminate the worker; never call
  native inference concurrently with teardown inside the same process.
- Proposed escalation: request exit, wait up to 1 second, terminate, then kill after
  another 1 second if needed. Reap the child before admitting work to its successor.
- A worker crash fails that request. Do not retry the recording automatically;
  restart lazily for the next user request and avoid an automatic crash loop.

Cancellation that wins before display/Copy initiation prevents that effect. Cancellation
after a clipboard write cannot undo that effect or the user's later paste; communicate
the boundary accurately. Tests must exercise both orderings rather than promise
an impossible rollback.

The review transcript, Vim register and undo state are app-owned memory after
server completion. Dismiss, a new recording or app exit discards them; do not
accumulate a transcript list or serialize editor state.

## 8. macOS capture, editable review and Copy

Use native microphone capture and sample-rate conversion. Check permissions before
recording, handle device loss/interruption explicitly, and never persist captured
audio. An interruption cancels capture rather than delivering an unexplained
partial prompt. The five-minute cap intentionally produces a partial recording;
it is a separate, documented completion path. Warn at 4:45; Stop and 5:00 cap
firing must converge on one completion. Cancel discards rather than transcribes.
Record/Stop are menu-bar controls; there is no global shortcut or key injection.

Every live nonempty result enters editable review. Standard native editing is the
default. Optional Vim mode is selected by the TOML schema in §3. This table is the
bounded agreed command set, not a promise of full Vim compatibility:

| Area | Supported keys / behavior |
| --- | --- |
| Modes | Vim starts in Normal with a visible mode label; Normal, Insert, character Visual and line Visual; `i`/`a` enter Insert before/after cursor, Escape returns to Normal, `v`/`V` enter character/line Visual |
| Motions | `h`/`j`/`k`/`l`, `w`/`b`/`e`, `0`/`$`, `gg`/`G`, counts for supported motions/commands |
| Changes | `x`, `dd`, `dw`, `cw`; `cw` enters Insert |
| Register | `yy`, `p`; Vim deletes/yanks/paste use an in-memory register, never the macOS clipboard |
| History | `u`, `Ctrl-R`; in-memory undo/redo, cleared with the transcript |
| Native editing | Cmd-A selects all; Cmd-C copies selected text; Copy all / Cmd-Shift-C copies the entire edited buffer. Native paste and undo remain available; every system clipboard cut/copy route uses the currentHostOnly writer |
| Enter | Inserts a newline only in Standard editing or Vim Insert mode; never submits |
| Excluded | Ex commands, plugins, macros, dot-repeat, external editor integration and broader Vim emulation |

Fixtures must exercise the entire table in multiline and empty text, word/line
boundaries, counts, mode transitions, Visual selections, undo/redo and register
lifetime; unsupported commands must not invoke an external editor or write the
clipboard. Escape in review is an editor-mode action; Dismiss is explicit and
keyboard-accessible. Standard editing and native Command routes must remain usable
with Vim enabled. #22 implements/tests these details, not this document.

One app-owned clipboard adapter must mediate the Copy button, keyboard equivalents,
menu/context-menu Copy and Cut, and native Command-C/Command-X in either editor
mode. Use `NSPasteboard` current-device-only writes (`currentHostOnly`); do not let
a default text-view responder bypass that policy. Explicit Copy all / Cmd-Shift-C
copies the entire current edited buffer; Cmd-C and native selection Copy/Cut act
on the selected text. Empty text must not clobber the clipboard.
Vim's register operations never use that adapter. Native paste reads the clipboard
into review only; it never targets another application. No clipboard change on
result display, edits, internal Vim operations or Dismiss. Copy feedback reflects
write success and is invalidated by edits; failure retains text for retry.

Do not restore or clear the user's clipboard. Current-device-only writes do not
control local clipboard managers or destination retention/transmission. Require
the second-device check with an ordinary-copy positive control in PRD AC5.

No Accessibility destination inspection, app/window/input identity snapshot,
focus restoration, simulated paste, or automatic submission is in this milestone.
The constitution's stricter rules still govern any future automatic delivery;
AC1/AC2 destination work is deferred, not a blocking feasibility spike for Copy.
Review can take editor focus intentionally. Routine feedback must not activate a
destination. Respect reduced motion, native accessibility names and model display.

## 9. CLI contract

Planned alpha command surface; `transcribe` and `model install` are not implemented:

```text
hagig transcribe <audio.wav>
hagig model install <manifest-id>
hagig status
hagig stop
```

`status` and `stop` already exist in #7's controlled lifecycle CLI. Current
`start --fake-worker` and `fake-request --fake-worker` explicitly select a
controlled fake, never inference or model installation. Both modes of that slice
and its build instructions live in backend guidance; no complete app startup
command exists yet. App launch must eventually start/connect to the bundled real
server, not silently select the fake worker.

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

### Tool and dependency approval inventory

This documentation change needs no new dependency, installation or tool.
Repository guidance owns approval policy; this inventory records its application
to the milestone, not an additional grant:

| Surface | Approval / constraint |
| --- | --- |
| Rust starting set | `tokio` (needed features only), `serde`, `serde_json`, `clap`, `toml`, either `rustix` or `nix` when std is insufficient (not both), `tempfile` for tests; existing backend uses rustix |
| Inference | Existing pinned sherpa-onnx candidate only subject to #6/#25 adoption; audit transitive/native build, model-loader and download paths, licensing separately from privacy; no new engine/plugin framework |
| Native editor/UI | Existing Swift/AppKit/SwiftUI and shared render harness; no external editor, Vim dependency or new tool needed for this contract |
| Build/test | Existing Rust/Swift/Xcode and repository commands; GitHub-hosted native CI for development, normal automatic CI allowed in this run; ask before any manual workflow dispatch |
| Network observation | Distro-packaged strace approved for Linux observation only, not an app dependency; other new development tools need specific approval |
| Not selected | Download/checksum/WAV/resampling libraries and additional build tools require owner approval before introduction; no DI or async-trait crate needed |
| Packaging | Local ad-hoc signing as needed; public certificates/notarization, releases and Homebrew-tap writes deferred and not granted |

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
| Physical Mac | Record/Stop, permissions, microphone/device loss, native editor/keyboard routing, cancel/Copy races, second-device clipboard control, relocated local app and human usefulness; owner final tests deferred |
| Privacy | Distinct source inspection, observed network/write behavior, blocked-network operation; include failure and recovery paths |

Automated fake-worker tests should intentionally return results after cancellation,
reuse request IDs across generations, crash while active, and stall. At least one
real-worker test must establish recovery after process death. Verify service/process
cleanup, not just returned text. An additional Apple device is needed for the
observational Universal Clipboard check; API inspection alone is not that evidence.

The prototype's browser checks establish only the HTML artifact's behavior.
GitHub-hosted macOS build, shared-view rendering and feasible automated native
interaction checks are the development path. Prove/inspect the Ready artifact
path before representative state collection; the synthetic shell has historical
render evidence, not real capture/editing evidence. Hosted checks do not replace
physical-Mac, second-device or human-corpus acceptance. Use synthetic non-sensitive
public fixtures only; do not assume acceleration availability in a VM. PRD §5
owns the AC-to-ticket/environment evidence matrix; do not duplicate it here.

## 12. Spike-first implementation sequence

The ticket backlog now exists; this table retains bounded risk investigations,
not a new architecture or an additional time/spend cap. #7 is merged and present;
do not reimplement it. Keep experiments scoped and report exhausted evidence paths
honestly rather than claiming acceptance. #6 remains blocked/partial in PR18.

| Spike | Question, evidence, and exit decision | Unblocks |
| --- | --- | --- |
| S1: inference and vocabulary (#6) | Can Rust run the candidate and expose boosting? Produce build recipe, exact artifacts, paired outputs, latency/memory and long-input measurements under AC6–AC8; numeric targets are not first-working-app gates. Resolve binding/adoption blockers with evidence, not assumed adoption. | Real worker/file transcription, audio conversion |
| S2: native copy-only path (#21/#22) | Validate Record/Stop/cap/Cancel, editable Standard/Vim review, all currentHostOnly cut/copy routes and keyboard/accessibility behavior. No destination-identity or automatic-paste spike in this milestone. | Usable capture/review/Copy, final platform acceptance |
| S3: packaging and privacy | Can the chosen native stack run from a relocatable self-contained bundle without forbidden runtime behavior? Produce loader/install evidence plus separate source/network/write/blocked-network findings. Proceed, patch dependencies, or reject adoption. | Distribution layout, dependency lock-in, alpha installation |

S1 and S2 can run independently using hosted Mac development evidence. Begin source
privacy review during S1 rather than after adoption; S3's final native packaging
and runtime evidence depends on the candidate S1 selects. Stop early on a privacy
violation rather than spending the remaining spike budget on speed measurements.

Then implement vertical slices:

1. **Existing scaffold:** #7 controlled lifecycle and synthetic Swift shell are
   present. Extend them; their fake/synthetic results are not real dictation.
2. **File to text:** real CLI → server → isolated worker, explicit model install,
   WAV input, one active request, errors and cancellation. AC8–AC13 as applicable.
3. **Record to review:** #21 Swift capture → same server → #22 editable in-memory
   transcript, explicit Copy/Dismiss, cap and permissions. AC3–AC5, AC9, AC14.
4. **Local bundle:** #23 can begin bundle feasibility early; its built artifact
   against integrated capture/editor/backend feeds final #10 acceptance. Do not
   make their issue closure dependencies circular.
5. **Daily-use alpha:** #10 held-out human measurements and mandatory privacy/
   failure evidence; owner physical Mac/second-device tests remain deferred, not
   satisfied by CI. #24 public distribution follows separately.

Each eventual ticket should name a user-visible or risk-retirement outcome, relevant
ACs/constitutional boundaries, dependencies, bounded scope, verification environment,
and required evidence. Do not organize tickets as isolated Swift/server/CLI silos.
Create external tracker issues only when requested.

## 13. Decisions to review, and evidence still missing

Settled owner choices: Standard default, optional bounded Vim, menu-bar Record/
Stop without a global shortcut, 5:00 cap/4:45 warning, local bundle before separate
distribution, required-default/explicit-disabled isolation, and functionality-first
numeric measurements. Do not reopen these as unanswered gates. WAV formats,
restart-to-apply configuration, remaining resource caps and hard deadlines retain
their proposed status until implementation evidence validates them; changes must
not silently alter safety/privacy commitments.

No review can substitute for these still-unverified facts:

- Exact Rust binding coverage and model/tokenizer/native dependency pins.
- Native capture/editor/clipboard routing and cancellation boundary behavior.
- Actual latency, correction burden, memory use, native loading, and privacy behavior.
- Validated local app build/terminal launch recipe, hosted exact-head evidence,
  and owner final physical-Mac/human/second-device tests and consented fixtures.

Resolve technical unknowns through S1–S3. If evidence contradicts an agreed product
or constitutional requirement, document the conflict and obtain an explicit decision;
do not relabel an unsafe implementation as satisfying the requirement. Missed
numeric performance/usefulness targets must be reported as measurements, not
misrepresented as either passing results or unagreed first-working-app blockers.
