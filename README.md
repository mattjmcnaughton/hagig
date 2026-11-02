# Hagig

**Think aloud, keep coding.**

Hagig is a planned privacy-first, local voice-to-text app for dictating spoken
instructions to coding agents. It targets macOS on Apple Silicon first, with a
portable Rust backend and a future Linux path.

## Status

This repository contains an adopted [constitution](docs/CONSTITUTION.md), design
documents, and a first [native macOS synthetic shell](clients/macos/AGENTS.md).
The shell and native screenshot harness share SwiftUI views. The first
[native CI evidence](https://github.com/mattjmcnaughton/hagig/actions/runs/40509803030)
passed build and three presentation tests on macOS 15.7.9 arm64 / Xcode 16.4;
both Ready images and 26 state images were inspected. This establishes static
view rendering, not application interactions or dictation. The merged #7
[controlled backend lifecycle](backend/AGENTS.md) supports a separate fake worker,
single-request admission, cancellation and server stop; it is not transcription.
There are no installation packages or implemented transcription features. The
#6 candidate in [PR #18](https://github.com/mattjmcnaughton/hagig/pull/18) remains
partial and blocked; inference has not passed its adoption gate.
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
of project names and technical vocabulary matters, so vocabulary boosting is an
MVP requirement. Initial transcription is English-only.

## Intended architecture

- **Swift macOS app:** menu-bar Record/Stop, microphone capture, permissions,
  in-memory editing and explicit Copy. Its home is `clients/macos/`; only synthetic
  presentation and explicit Copy are implemented in the initial shell.
- **Rust server:** session state and inference-worker supervision.
- **Rust worker:** a separate process calling an existing speech-recognition
  library, rather than a new recognition engine built for Hagig.
- **Rust CLI:** a sibling client of the server for transcribing existing audio
  files and controlling the server, including `hagig stop`. It does not record
  microphone audio.

The working design uses an on-demand, per-user server accessed through a
Unix-domain socket protected by OS permissions. It accepts one active request at a
time and rejects overlapping requests as busy. The worker stays warm between
requests; closing a client does not shut down the server. An explicit server stop
cancels active work and shuts down the worker and server.

The first inference configuration to evaluate is **sherpa-onnx with NVIDIA
Parakeet TDT 0.6B v2**, using modified beam search for vocabulary boosting. Native
packaging, Rust binding coverage and privacy remain validation gates; accuracy
and latency require measurements, not first-working-app numeric gates. None is
an established capability of this repository.

Configuration will be human-editable text at
`$XDG_CONFIG_HOME/hagig/config.toml`, defaulting to
`~/.config/hagig/config.toml`, including on macOS. TOML is the working format;
model, runtime, and state locations will be specified separately in the technical
design.

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
a general inference-engine plugin framework. A clone-buildable, relocatable local
`.app` launched from a terminal is planned in #23, not implemented. No Homebrew,
public release, notarization or `/Applications` placement is a prerequisite;
distribution is separately tracked in #24. Existing runnable scaffold commands
live in [backend guidance](backend/AGENTS.md) and native guidance below; they do
not build or launch the planned complete app.

Linux can validate portable Rust behavior and inference experiments. macOS builds
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
