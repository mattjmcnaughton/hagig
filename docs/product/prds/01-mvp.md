# Hagig MVP product requirements

Status: draft for owner review; not implemented or validated.

This document records the private-alpha requirements agreed in the design
discussion and proposes measurable acceptance criteria where the discussion left
room for judgment. The [constitution](../../CONSTITUTION.md) governs privacy and safety;
the [technical design](../../technical/tdds/01-mvp.md) owns implementation details.

## 1. Product and release boundary

Hagig lets its owner dictate spoken coding-agent instructions into the input they
are already using. It should be faster than fast typing **after accounting for
corrections**, not merely fast at inference.

The MVP is a private alpha that the owner can install and use daily on their own
Apple Silicon Mac. It is not a public release or a promise of compatibility with
every Mac, terminal program, or website.

The acceptance machine is an M4 Mac with 48 GB RAM, currently running macOS
Sequoia 15.7.3. Record the actual OS version when testing; an OS update requires
rerunning platform-sensitive acceptance checks. No Mac execution access has yet
been established from this orb.

Required destinations:

- Ghostty, including terminal-based coding-agent prompts and ordinary shell input.
- Chrome editable inputs, with Amp's prompt composer on ampcode.com as the first
  concrete browser acceptance target.

Hagig must not depend on which coding-agent CLI is running. This does not mean
that every terminal application interprets paste identically. Unsupported or
unverifiable destinations must fail safely rather than receive a speculative paste.

## 2. Scope

### Included

- Native macOS menu-bar application; configurable hold-to-record global shortcut.
- Microphone capture, release-to-transcribe, and Escape cancellation.
- English transcription using one local inference configuration.
- Vocabulary boosting for project names and technical terms.
- Focus-safe automatic paste, without submitting, plus Copy/Dismiss fallback.
- Human-editable TOML configuration and explicit model installation.
- Required-by-default worker network isolation, with explicit user opt-out as a
  supported mode; never automatic fallback to disabled isolation.
- Rust server, isolated inference worker, and file-transcription CLI.
- Self-contained Apple Silicon app bundle without a separately installed Rust,
  Python, or inference-library runtime.
- Clear missing-model, permission, busy, and inference-failure behavior.
- Evidence for the constitution's privacy and isolation requirements.

### Excluded

- Public release, Homebrew cask, public onboarding, signing/notarization service,
  automatic updates, and broad OS/hardware support commitments.
- Linux desktop app, multilingual transcription, literal source-code dictation,
  coding-agent plugins, MCP, and an inference-engine plugin framework.
- Streaming transcripts, transcript editing/history/search, recorded-audio history,
  clipboard backup/restoration or cleanup, and a settings GUI.
- Microphone recording from the CLI, queued requests, and preempting another client.

Public distribution is deferred, not a reason to ignore private-alpha installation
or native-library loading. Local signing and permissions needed to run on the
owner's Mac remain part of the alpha.

## 3. User workflows

### P1. Dictate into the current input

1. Focus a Ghostty prompt or Chrome input.
2. Hold the configured shortcut. If ready and not busy, Hagig begins capture and
   displays a recording indicator without stealing the destination's focus.
3. Release the shortcut. Capture stops and the transcription indicator appears.
4. If the original intended input can still be verified, request a paste there.
5. The user reviews the text and explicitly submits it themselves.

Never automatically press Enter or submit. Do not change focus to make a paste
possible. Do not claim that requesting paste universally confirms its completion.

### P2. Recover when the destination changes or is unverifiable

If the intended input cannot be verified at delivery time, do not automatically
write the clipboard or paste. Show the transcript in a fallback popover with an
inline copy icon and Dismiss. Copy is explicit and does not initiate paste; Dismiss
discards the pending transcript. Keep the transcript in memory only.

The fallback must handle changes within the same application, including Ghostty
tabs/panes and Chrome tabs/inputs. A foreground-application match alone is not
verification. What each application exposes must be established by a native spike.

### P3. Cancel

Escape during capture or transcription cancels the request and discards pending
content. Cancellation must prevent a late result from subsequently appearing,
copying, or pasting. Dismiss discards fallback content. Cancellation cannot undo a
clipboard write or paste already initiated.

### P4. Handle long recordings and silence

Capture is capped at five minutes. Warn near the limit; reaching it stops capture
and transcribes the audio already recorded. A proposed warning threshold is
15 seconds before the cap, not a permanent warning on every recording.

Silence or a result containing no usable text must not write the clipboard or
paste. Return to ready with a brief, non-content-bearing indication that no speech
was recognized.

### P5. Set up and recover

The owner can follow documented installation steps, explicitly install the model,
edit TOML for the shortcut/vocabulary, and grant macOS permissions. A settings GUI
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
- Show the configured model's display name, initially Parakeet, and English.
- Inline copy icon next to fallback text, with accessible name and copy feedback.
- No clipboard-mechanics explanation or permanent recording-cap warning in the
  popover. Document privacy boundaries in setup/help instead.
- No live transcript during recording and no fabricated percentage or audio level.

Prototype-only state selectors, simulated actions, and demo badges are not proposed
production controls. Routine recording/transcription feedback must not take focus;
the fallback is an explicitly interactive surface after automatic delivery is
abandoned.

## 5. Acceptance criteria

Identifiers below are intended for traceability into tickets and verification.
The numeric corpus criteria are **proposed alpha gates**, not earlier agreements
or measured results. Review them before collecting final acceptance evidence.

| ID | Requirement and decisive check |
| --- | --- |
| AC1 | On the acceptance Mac, perform P1 in Ghostty and Chrome/Amp. Text reaches the original input and is not submitted. Include ordinary shell and actual coding-agent input. |
| AC2 | Change Ghostty tab/pane, Chrome tab/input, foreground application, or close the destination during capture/transcription. No text reaches a different input; changed or unverifiable targets offer Copy/Dismiss. |
| AC3 | Cancel during recording, worker startup, inference, and just before delivery. Delay or inject a late worker result: no display, clipboard write, or paste follows cancellation. Test both event orderings at the delivery boundary. |
| AC4 | Five-minute capture stops and transcribes captured audio; the pre-limit warning appears only near the cap. Test release/cancel around the boundary and confirm there is no duplicate request. |
| AC5 | Both automatic paste and explicit Copy use current-device-only clipboard writes. Confirm the API path and observe a second Apple device; document what that finite test establishes and excludes. No clipboard change occurs on fallback display or Dismiss. |
| AC6 | Proposed latency gate: on at least 20 warm 15–30-second prompts, at least 95% are text-ready within 2 seconds of release. Record every sample, median, p95, maximum, and separate delivery time. Exclude no failed requests silently. Cold starts and longer inputs are measured separately. |
| AC7 | Proposed usefulness gate: on 20 representative prompts, at least 18 are usable unchanged by the owner; the rest need only small corrections, not substantial rewriting. Speech plus wait plus correction is faster than the owner's measured typing baseline in median end-to-end time. |
| AC8 | Demonstrate vocabulary improvement on at least 10 term-bearing clips, with at least 10 non-vocabulary controls. Report paired boosted/unboosted results, missed terms, false insertions, and ordinary-word regressions. No material overall regression is accepted without explicit review. |
| AC9 | Silence, empty input, invalid configuration, unsupported file, missing/corrupt model, and busy each yield clear non-content-bearing outcomes without unintended delivery or automatic downloading. |
| AC10 | Crash or stall the worker; the app and server remain responsive, the affected request terminates without delivery, and a subsequent request can succeed. Stop and client-disconnect paths release the active slot. |
| AC11 | Validate normal dictation/file transcription using separate dependency source review, observation of attempted networking and local writes, and execution with outbound networking blocked. Required isolation is the default and refuses startup if unavailable, without automatic fallback. Explicit disabled mode retains a separate worker and offline/no-upload behavior but makes no OS-network-block claim; validate that mode separately on restricted hosts. Record the selected mode with evidence. Logs contain no audio, transcripts, vocabulary, or raw sensitive configuration. |
| AC12 | Install the alpha bundle on the acceptance Mac without developer-language runtimes or developer-checkout library paths. Explicitly install the model, grant permissions, transcribe, stop, and relaunch successfully. |
| AC13 | CLI WAV transcription outputs text only to stdout; failures use stderr/nonzero status; no clipboard side effects. The supplied input remains unchanged, including on cancellation and errors. |
| AC14 | Recording/transcribing states are distinguishable with and without animation. Copy and Dismiss are keyboard-accessible and named for assistive technology. |

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
after local recognition, before focus verification or clipboard operations. Also
measure release-to-paste-request/fallback-visible, because that is the user-facing
delay. Report cold/warm conditions, model/dependency pins, hardware, OS, and settings.

## 6. Release decision and outstanding evidence

The alpha is usable only after the mandatory safety/privacy criteria pass on real
macOS, not merely in the Linux orb. Performance and usefulness remain goals to
test; if the candidate cannot meet them, bring evidence and a scoped alternative
back for review rather than weakening the requirements silently.

Still needed:

- Owner review of the proposed numeric gates, warning timing, and CLI defaults.
- Mac runner or owner-operated native test path, plus representative fixtures.
- Inference/binding, focus/delivery, and packaging/privacy spike evidence.
- Final model/dependency pins and installation instructions.

Do not require another broad interview before drafting tickets. Use the bounded
spikes in the technical design to turn remaining technical uncertainty into
evidence and decisions.
