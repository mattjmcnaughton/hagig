# Hagig MVP product requirements

Status: agreed copy-only milestone scope (#20); not an implemented or accepted alpha.

This document records the private-alpha requirements and the owner's functionality-
first decision: retain numeric measurements without making their proposed targets
first-working-app blockers. Safety/privacy gates are unchanged.
The [constitution](../../CONSTITUTION.md) governs privacy and safety;
the [technical design](../../technical/tdds/01-mvp.md) owns implementation details.

## 1. Product and release boundary

Hagig lets its owner dictate spoken coding-agent instructions, review/edit them,
and explicitly Copy for manual paste into the input they choose. It should be
faster than fast typing **after accounting for corrections**, not merely inference.

The MVP is a private alpha that the owner can build and use daily on their own
Apple Silicon Mac. It is not a public release or a promise of compatibility with
every Mac, terminal program, or website.

The acceptance machine is an M4 Mac with 48 GB RAM, currently running macOS
Sequoia 15.7.3. Record the actual OS version when testing; an OS update requires
rerunning platform-sensitive acceptance checks. GitHub-hosted macOS CI is the
development path; final owner physical-Mac testing is deferred until their return.

Required manual-paste acceptance targets (not destinations Hagig inspects):

- Ghostty, including terminal-based coding-agent prompts and ordinary shell input.
- Chrome editable inputs, with Amp's prompt composer on ampcode.com as the first
  concrete browser acceptance target.

Hagig must not depend on which coding-agent CLI is running. The user switches to
the target, pastes and submits; Hagig never inspects, focuses or injects keys there.

## 2. Scope

### Included

- Native macOS menu-bar application with Record/Stop controls, no global shortcut.
- Microphone capture, Stop-to-transcribe, and Escape/Cancel cancellation.
- English transcription using one local inference configuration.
- Vocabulary biasing for project names and technical terms.
- Editable in-memory transcript review, explicit Copy and Dismiss; no auto-copy.
- Standard native editing by default; optional bounded Vim via TOML, with the
  authoritative key table and clipboard routing in TDD §8.
- Human-editable TOML configuration and explicit model installation.
- Required-by-default worker network isolation, with explicit user opt-out as a
  supported mode; never automatic fallback to disabled isolation.
- Python server, isolated inference worker, and file-transcription CLI.
- Clone-buildable, relocatable Apple Silicon app bundle, terminal launch, without
  requiring `/Applications` placement or a separately installed Python, uv,
  or inference-library runtime; the bundle ships its own interpreter.
- Clear missing-model, permission, busy, and inference-failure behavior.
- Evidence for the constitution's privacy and isolation requirements.

### Excluded

- Public release, Homebrew cask, public onboarding, signing/notarization service,
  automatic updates, and broad OS/hardware support commitments.
- Linux desktop app, multilingual transcription, literal source-code dictation,
  coding-agent plugins, MCP, and an inference-engine plugin framework.
- Automatic paste/submission, destination-identity/focus work and global shortcuts.
- Streaming transcripts, transcript history/search, recorded-audio history,
  clipboard backup/restoration or cleanup, and a settings GUI.
- Microphone recording from the CLI, queued requests, and preempting another client.

Public distribution (#24) is separate, not a source-build prerequisite. The local
app build (#23), terminal launch, relocation, native loading, ad-hoc signing as
needed and permissions remain planned alpha work, not implemented commands.

## 3. User workflows

### P1. Record, review and Copy

1. Open the menu-bar surface and choose Record. Admission precedes capture.
2. Speak, then choose Stop; capture stops and transcription feedback appears.
3. Review/edit the returned text using Standard or configured Vim mode.
4. Explicitly Copy the current edited text; Copy does not paste or submit.
5. Manually switch to Ghostty or Chrome/Amp, paste, review and submit yourself.

No automatic clipboard write on result, editing or opening review. Never
automatically paste, press Enter, submit, inspect a destination or restore focus.

### P2. Edit or discard a result

Every nonempty result opens editable review, not an exceptional fallback. Copy
uses the current edited text with current-device-only sharing; Dismiss discards
pending content without changing the clipboard. Repeated Copy is explicit each
time, and edits invalidate stale copy feedback. Keep one transcript in memory only.

Standard editing is the default. Vim is bounded, not full Vim or an external editor;
its register/undo state is ephemeral. Native Command-key cut/copy routes must use
the same current-device-only boundary as the Copy control. See TDD §8 for keys.

### P3. Cancel

Escape during capture or transcription cancels the request and discards pending
content. Cancellation must prevent a late result from subsequently appearing,
copying, or pasting. Dismiss discards review content. During Vim review Escape
returns to Normal mode, not cancellation; Dismiss remains explicit. Cancellation
cannot undo a clipboard write already initiated or a user's subsequent paste.

### P4. Handle long recordings and silence

Capture is capped at five minutes. Warn at 4:45; reaching 5:00 stops capture and
transcribes the audio already recorded. Stop and the cap converge on one
completion; Cancel discards instead. No permanent warning on every recording.

Silence or a result containing no usable text must not write the clipboard or
paste. Return to ready with a brief, non-content-bearing indication that no speech
was recognized.

### P5. Set up and recover

The owner can follow documented installation steps, explicitly install the model,
edit TOML for editor mode/vocabulary/isolation, and grant macOS permissions. A settings GUI
is unnecessary. Missing/corrupt models must produce actionable errors, never a
silent download. Worker failure must leave the app usable for a new request.

Only one request can be active across app and CLI. A competing request receives
busy immediately, without being queued or cancelling the existing request.

Closing a client does not stop the shared server or idle warm worker. Closing the
client that owns active work cancels that work. An explicit server stop cancels
active work and stops both server and worker.

### P6. Transcribe an existing file

The CLI uses the same server and inference configuration as the app. It accepts
existing user-owned audio files, returns text to stdout, and does not access the
clipboard or simulate paste. Proposed alpha format support is WAV only; details
belong in the technical design. Input files must not be modified or deleted.

## 4. UI direction

The reviewed [static prototype](../prototypes/README.md) is a design reference,
not evidence of a working application. Its editable sources live in
`docs/product/prototypes/`, not the native app source tree. Generated HTML and
captures remain untracked artifacts.

Carry forward these decisions:

- Compact menu-bar surface, not a full application window or dashboard.
- Visually distinct recording pulse and indeterminate transcription spinner.
- Respect reduced motion; retain readable state labels without animation.
- Show the configured model's display name, initially Qwen3-ASR, and English.
- Editable review with an inline copy icon, accessible name and copy feedback.
- No clipboard-mechanics explanation or permanent recording-cap warning in the
  popover. Document privacy boundaries in setup/help instead.
- No live transcript during recording and no fabricated percentage or audio level.

Prototype-only selectors, simulated actions, and demo badges are not production
controls. Review is explicitly interactive; recording/transcription feedback must
not spuriously activate another application. Menu controls require no global hook.

## 5. Acceptance criteria

Identifiers below are intended for traceability into tickets and verification.
AC identifiers are retained for traceability. AC1/AC2's former automatic-paste and
destination-identity requirements are deferred, not claimed as passed. AC6–AC8
retain the original numeric proposals as measurement references under the owner's
functionality-first decision, not first-working-app blockers. Do not silently
exclude failures or imply safety/privacy, cancellation or silence gates are optional.

| ID | Requirement and decisive check |
| --- | --- |
| AC1 | Deferred automatic delivery; instead perform P1 with manual paste into Ghostty shell/coding-agent input and Chrome/Amp. Record the human workflow, showing no automatic paste/submission. |
| AC2 | Deferred destination-identity matrix. Copy-only checks must establish that Hagig neither inspects destinations nor sends paste/focus events; result display alone does not write the clipboard. |
| AC3 | Cancel during recording, worker startup, inference, and just before delivery. Delay or inject a late worker result: no display, clipboard write, or paste follows cancellation. Test both event orderings at the delivery boundary. |
| AC4 | Five-minute capture stops and transcribes captured audio; warning appears at 4:45. Test Stop/cap/Cancel around both boundaries and confirm no duplicate request or delivery after Cancel. |
| AC5 | Explicit Copy and every native cut/copy route use current-device-only clipboard writes. Inspect API routing and observe a second Apple device with an ordinary-copy positive control. No clipboard change on result display, internal Vim operations or Dismiss. |
| AC6 | Latency measurement: at least 20 warm 15–30-second prompts; reference target is 95% text-ready within 2 seconds of Stop. Record every sample, median, p95, maximum and failures; separate review-visible and user Copy timing. Measure cold starts and longer inputs separately. |
| AC7 | Usefulness measurement: 20 representative prompts; reference target is 18 usable unchanged, remaining prompts needing only small corrections, and median speech + wait + correction faster than measured typing. Report correction burden and total time even if targets are missed. |
| AC8 | Vocabulary measurement: at least 10 term-bearing clips and 10 non-vocabulary controls. Report paired biased/unbiased outputs, missed terms, false insertions and ordinary-word regressions. Vocabulary biasing remains required functionality; measured improvement and regressions inform follow-up rather than block the first working app. |
| AC9 | Silence, empty input, invalid configuration, unsupported file, missing/corrupt model, and busy each yield clear non-content-bearing outcomes without unintended delivery or automatic downloading. |
| AC10 | Crash or stall the worker; the app and server remain responsive, the affected request terminates without delivery, and a subsequent request can succeed. Stop and client-disconnect paths release the active slot. |
| AC11 | Validate normal dictation/file transcription using separate dependency source review, observation of attempted networking and local writes, and execution with outbound networking blocked. Required isolation is the default and refuses startup if unavailable, without automatic fallback. Explicit disabled mode retains a separate worker and offline/no-upload behavior but makes no OS-network-block claim; validate that mode separately on restricted hosts. Record the selected mode with evidence. Linux initially has no required-mode implementation, so it runs only in explicit disabled mode. Logs contain no audio, transcripts, vocabulary, or raw sensitive configuration. |
| AC12 | Clone/build the local bundle, launch from a terminal, relocate outside the checkout and launch again without separately installed developer/inference runtimes or checkout library paths. Explicitly install the model, grant permissions, transcribe, stop and relaunch. Build tools are needed for building, not running the artifact. No release/Homebrew or `/Applications` prerequisite. |
| AC13 | CLI WAV transcription outputs text only to stdout; failures use stderr/nonzero status; no clipboard side effects. The supplied input remains unchanged, including on cancellation and errors. |
| AC14 | Recording/transcribing states are distinguishable with and without animation. Copy and Dismiss are keyboard-accessible and named for assistive technology. |

### Evidence mapping and current gaps

These are required evidence plans, not results. The synthetic native shell covers
foundations only; the Python backend is planned and no inference is adopted.
#10 owns final combined acceptance after #23's artifact;
#24 distribution does not block a source build.

| ACs | Concrete evidence / owning work | Environment and missing evidence |
| --- | --- | --- |
| AC3, AC10 | Python backend public server/worker tests: cancel in each phase, delayed/stale completion, crash/stall, disconnect/stop, reap and successful next request; #21 app generation/copy race tests | Linux and hosted Mac can exercise controlled faults; real inference and native app path still needed; owner physical Mac final |
| AC4 | #21 clock-controlled Stop/cap/Cancel tests plus real timed capture: 4:45 warning, 5:00 single completion | Hosted native tests for boundaries; physical microphone duration/device behavior deferred |
| AC5 | #22 editor and clipboard adapter tests for button, keyboard and menu cut/copy, all supported Vim operations and Dismiss; inspect currentHostOnly; #10 second-device observation | Hosted Mac validates API/interaction paths, not cross-device locality; owner second Apple device with ordinary-copy control deferred; local clipboard managers remain outside control |
| AC6–AC8 | Python backend and #10 pinned-model runs and raw sample tables, paired controls, failures, timings and owner correction/typing comparison | Synthetic public CI for development only; consented held-out human corpus and acceptance hardware measurements deferred; no personal audio in public artifacts |
| AC9 | Python backend and #21 negative fixtures: silence/noise/empty, bad config/WAV, missing/corrupt model and busy; observe no delivery/download and recovery | Portable CLI and hosted native app checks; real microphone silence/noise on physical Mac remains required |
| AC11 | Python backend finite source/transitive/model-loader audit; runtime attempted-network/write observation and blocked-network tests, both explicit modes, failure/recovery controls | Hosted macOS Seatbelt evidence recorded separately; Linux has disabled mode only; required refusal is not enforcement success, disabled success is not blocking evidence; full pinned inference privacy/adoption unproven |
| AC12 | #23 local build/terminal launch/relocation/native loader and ad-hoc-signing evidence, then #10 final artifact exercise | Hosted Mac build/relocation during development; owner physical-Mac permissions/run deferred; recipe and complete artifact not implemented |
| AC13 | Python backend real WAV CLI tests: stdout/stderr/status, supported formats, cancellation/failures, unchanged input digest, no clipboard calls | Linux and hosted Mac; test-fake success does not prove transcription |
| AC14 | #21/#22 shared SwiftUI renders, keyboard/pointer/accessibility and Standard/Vim editing fixtures, reduced-motion behavior | Ready artifact path already demonstrated for synthetic shell; new native interactions and final owner review still needed; Linux HTML/stills are not interaction evidence |

### Measurement protocol

Use the owner's real microphone, speaking style, and intended coding instructions.
Include technical terms, punctuation, names, short instructions, and longer
multi-clause requests. Use silence and ambiguous speech as negative controls.

Prepare reference text and a typing baseline independently of recognizer output.
Use held-out prompts for final acceptance rather than tuning vocabulary/decoder
settings against every final clip. Benchmark fixtures must be explicitly supplied
or recorded for that purpose: they are not permission to retain daily dictation.
Do not commit personal prompts or recordings by default.

For AC6, text-ready means an accepted, nonempty transcript is available to the app
after local recognition, before editing or clipboard operations. Also measure
Stop-to-review-visible and correction/Copy time separately. Report cold/warm
conditions, model/dependency pins, hardware, OS and settings. Reference targets
above are measurements, not new acceptance blockers.

## 6. Release decision and outstanding evidence

The alpha is usable only after the mandatory safety/privacy criteria pass on real
macOS, not merely in the Linux orb. During development use hosted native CI;
deferred owner physical-Mac, human and second-device tests remain outstanding,
not waived. Performance/usefulness measurements do not block the first working
app; safety/privacy and silence/noise outcomes still do.

Still needed:

- Exact local app build/terminal launch recipe and relocated artifact (#23).
- Hosted exact-candidate native evidence plus final owner-operated physical-Mac,
  human corpus and second-device tests; consented fixture handling if supplied.
- Inference/binding and packaging/privacy evidence; automatic delivery is deferred.
- Final model/dependency pins and installation instructions.

Do not require another broad interview before drafting tickets. Use the bounded
spikes in the technical design to turn remaining technical uncertainty into
evidence and decisions.
