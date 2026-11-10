# Hagig

**Think aloud, keep coding.**

Hagig is a planned privacy-first, local voice-to-text app for dictating spoken
instructions to coding agents. It targets macOS on Apple Silicon first, with a
portable Python backend and a future Linux path.

## Status

Main is an **experimental development build, not an accepted alpha**. Besides the
adopted [constitution](docs/CONSTITUTION.md) and design documents, it contains:

- **Native macOS client (#21, #22):** menu-bar Record/Stop/Cancel. Capture starts
  only after backend admission, audio stays in memory as canonical PCM, and a
  Unix-socket client talks to the service. Review is editable (Standard or
  bounded Vim), Copy/Cut are explicit and current-host-only, and the shell shares
  its SwiftUI views with the native screenshot harness. See
  [native guidance](clients/macos/AGENTS.md).
- **Local app assembly (#23):** `clients/macos/bundle.sh` assembles an ignored,
  ad-hoc-signed `Hagig.app` from explicitly prepared native helpers. The
  [local experiment recipe](clients/macos/AGENTS.md#local-source-experiment-after-the-gated-merges)
  builds and launches it from a clone.

The Python backend (per-user server, isolated inference worker and CLI, serving a
REST API over a private Unix socket) is planned; the
[technical design](docs/technical/tdds/01-mvp.md) owns its contract.

Native state renders and a synthetic interaction recording were inspected. None
of this is acceptance of physical microphone capture, permissions, devices or
rebuilds, second-device clipboard locality, model quality, privacy or inference
adoption. No inference candidate has passed its adoption gate. Owner physical-Mac
checks remain open in #21, #23 and #10. There are no installation packages or
releases (#24).

[MVP product requirements](docs/product/prds/01-mvp.md) own copy-only scope and
acceptance; the [technical design](docs/technical/tdds/01-mvp.md) owns configuration,
the bounded Vim key table and implementation contracts. The behavior below is
intended, not a claim that the alpha works today.

The [product prototype](docs/product/prototypes/README.md) preserves the reviewed
UI concept as an editable, standalone browser simulation, not native app code.

## Intended experience

1. Choose Record in the menu-bar app and speak; choose Stop to transcribe locally.
2. Review and edit the in-memory transcript: Standard editing is the default;
   optional bounded Vim editing is selected through TOML.
3. Explicitly Copy, then manually switch to Ghostty or Chrome/Amp and paste and
   submit yourself. Dismiss discards the pending text.

No global shortcut, automatic paste, destination inspection, focus restoration or
automatic submission is part of this milestone. Copy and any native clipboard
cut/copy route must disable cross-device Universal Clipboard sharing for that
write. Vim's internal register stays in memory, not the system clipboard.

Escape cancels recording or transcription and prevents later delivery of that
request's result. Recording is capped at five minutes, with a warning at 4:45;
reaching the limit stops capture and transcribes the audio already recorded once.
In Vim review, Escape returns to Normal mode rather than dismissing the transcript.

The focus is spoken instructions, not literal source-code dictation. Recognition
of project names and technical vocabulary matters, so vocabulary biasing is an
MVP requirement. Initial transcription is English-only.

## Intended architecture

- **Swift macOS app:** menu-bar Record/Stop, microphone capture, permissions,
  in-memory editing and explicit Copy. Its home is `clients/macos/`, where the
  experimental client awaits physical-Mac acceptance.
- **Python server:** session state and inference-worker supervision.
- **Python worker:** a separate process calling an existing, maintained
  speech-recognition library, rather than a new recognition engine built for Hagig.
- **Python CLI:** a sibling client of the server for transcribing existing audio
  files and controlling the server, including `hagig stop`. It does not record
  microphone audio.

The working design uses an on-demand, per-user server accessed through a
Unix-domain socket protected by OS permissions, speaking HTTP/1.1; there is no
TCP listener. It accepts one active request at a
time and rejects overlapping requests as busy. The worker stays warm between
requests; closing a client does not shut down the server. An explicit server stop
cancels active work and shuts down the worker and server.

The first inference configuration to evaluate is **Qwen3-ASR through Hugging Face
transformers on PyTorch**, biased toward configured vocabulary through its context
prompt. Packaging and privacy remain validation gates; accuracy
and latency require measurements, not first-working-app numeric gates. None is
an established capability of this repository.

Planned backend configuration is human-editable TOML at
`$XDG_CONFIG_HOME/hagig/config.toml`, defaulting to
`~/.config/hagig/config.toml`, including on macOS. Validated model, editor,
isolation and vocabulary settings are frozen for the server lifetime; apply edits
by explicitly stopping/relaunching the server. Runtime never downloads or repairs
missing/corrupt models. The [technical design](docs/technical/tdds/01-mvp.md) owns
concrete model/runtime locations and the client API.

## Privacy boundaries

Normal dictation must work offline, without telemetry, uploads, or automatic
recovery downloads. Explicit model downloads are acceptable. Hagig must not
persist recordings or transcripts by default, including through diagnostics, and
must avoid leaking sensitive vocabulary through logs.

Clipboard managers and receiving applications can retain or independently
transmit delivered text. Disabling Universal Clipboard does not control those
applications, and cancellation cannot undo delivery already initiated.

Dependency source review, runtime observation of networking and local writes, and
operation with networking blocked are separate required forms of evidence. None
has yet established runtime privacy for Hagig. Finite tests cannot prove absolute
privacy guarantees.

## Scope and development

The MVP excludes a Linux desktop app, MCP integrations, coding-agent plugins, and
a general inference-engine plugin framework. Experimental clone-buildable,
relocatable local `.app` assembly and terminal launch exist (#23); physical-Mac
launch, permission and rebuild acceptance is pending. No Homebrew, public
release, notarization or `/Applications` placement is a prerequisite;
distribution is separately tracked in #24. Developer commands live in the
native guidance below and, once the Python backend lands, its guidance.

Linux can validate portable Python behavior and inference experiments. It has no
OS-enforced worker network blocking initially, so it runs only in explicit
disabled isolation mode. macOS builds
and physical-Mac acceptance remain necessary for microphone permissions, native
editing/copy behavior, clipboard locality, packaging and human usefulness. Hosted
macOS CI supports development; final owner physical-Mac, human-corpus and
second-device checks are deferred, not replaced by synthetic or hosted results.
Numeric performance/usefulness/vocabulary targets are measurements for the first
working app, not blockers; mandatory safety/privacy gates remain unchanged.

Read [AGENTS.md](AGENTS.md) and the [constitution](docs/CONSTITUTION.md) before
contributing. [Native developer guidance](clients/macos/AGENTS.md) describes the
macOS commands, path-filtered build/tests and manually dispatched synthetic
screenshot workflow, including what each form of evidence cannot establish.

The name is inspired by Biblical Hebrew הֲגִיג, provisionally associated with
murmuring or musing; the precise wording remains to be verified.
