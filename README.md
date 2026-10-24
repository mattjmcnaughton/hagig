# Hagig

**Think aloud, keep coding.**

Hagig is a planned privacy-first, local voice-to-text app for dictating spoken
instructions to coding agents. It targets macOS on Apple Silicon first, with a
portable Rust backend and a future Linux path.

## Status

This repository is at the design stage. It contains project guidance and an
adopted [constitution](docs/CONSTITUTION.md), not a working application. There are
no installation packages, executable developer commands, or implemented
transcription features yet. The MVP product requirements and technical design are
next; the behavior below describes the intended product.

## Intended experience

1. Hold a configurable global shortcut and speak.
2. Release the shortcut to transcribe locally.
3. Paste into the verified, still-focused destination, including a coding-agent
   terminal. Never automatically press Enter or submit text.

If the destination changed or cannot be verified, show the transcript with Copy
and Dismiss instead. Both automatic paste and explicit Copy use the general
clipboard with cross-device Universal Clipboard sharing disabled for that write.

Escape cancels recording or transcription and prevents later delivery of that
request's result. Recording is capped at five minutes, with a warning before the
limit; reaching the limit stops capture and transcribes the audio already recorded.

The focus is spoken instructions, not literal source-code dictation. Recognition
of project names and technical vocabulary matters, so vocabulary boosting is an
MVP requirement. Initial transcription is English-only.

## Intended architecture

- **Swift macOS app:** shortcut handling, microphone capture, permissions, focus
  checks, and text delivery. Its planned home is `clients/macos/`.
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
packaging, Rust binding coverage, accuracy, latency, and privacy remain validation
gates—not established capabilities of this repository.

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
a general inference-engine plugin framework. Self-contained macOS distribution is
the target; packaging and signing are not implemented.

Linux can validate portable Rust behavior and inference experiments. macOS builds
and physical-Mac acceptance remain necessary for microphone permissions, global
shortcuts, focus checks, paste behavior, clipboard locality, and performance.

Read [AGENTS.md](AGENTS.md) and the [constitution](docs/CONSTITUTION.md) before
contributing. The initial foundation deliberately precedes application code,
CI, and developer-toolchain setup.

The name is inspired by Biblical Hebrew הֲגִיג, provisionally associated with
murmuring or musing; the precise wording remains to be verified.
