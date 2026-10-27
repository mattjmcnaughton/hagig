# Hagig Constitution

Adopted: 2026-10-24

Hagig is a privacy-first, local voice-to-text application for dictating spoken
instructions to coding agents. These principles govern its design and development.
They are obligations, not certification that the current implementation satisfies
them.

## 1. Local processing by default

Normal transcription must work offline, without telemetry, audio or transcript
uploads, or automatic recovery downloads. Model downloads require an explicit user
action. A missing or corrupt model must not silently trigger a download.

## 2. No application-maintained content history

Hagig must not persist captured recordings or transcripts by default, including
through logs or diagnostics. Existing audio files supplied to the CLI are
user-owned inputs, not recordings for Hagig to delete.

Clipboard and destination-application retention are separate boundaries that must
be documented. Vocabulary and other sensitive configuration must not leak through
error messages or diagnostic logs.

## 3. User-controlled delivery

Hagig must never automatically submit text or press Enter. Automatic paste requires
a verified, still-focused intended destination. When that cannot be established,
Hagig offers the transcript with Copy and Dismiss instead of automatically pasting
or changing focus.

Both automatic-paste and explicit-Copy clipboard writes must disable Universal
Clipboard sharing using the macOS current-device-only option. This does not
prevent local clipboard managers or destination applications from retaining or
independently transmitting text; Hagig must not claim otherwise.

## 4. Cancellation prevents delivery

A cancelled request must not subsequently display, copy, or paste its result.
This remains true if the inference worker completes after cancellation.
Cancellation cannot undo delivery already initiated.

## 5. Inference failures stay isolated

Native inference must run in a separate worker process. Worker failure must not
crash the macOS application or compromise the server's request state.

The inference worker must run with OS-enforced external-network isolation,
established before loading native inference code or model assets. If isolation
cannot be established, inference must fail closed rather than run unrestricted.
Process separation alone does not meet this requirement.

This boundary applies to inference, not a blanket sandbox around the application,
server, or CLI. Explicit model acquisition runs outside the inference worker;
it does not grant that worker network access. Platform mechanisms belong in the
technical design and must preserve the worker's required private IPC.

## 6. Privacy claims require evidence

Third-party dependencies, including transitive dependencies and model-loading
paths, must pass a privacy adoption gate. Evidence must distinguish:

1. Source inspection.
2. Runtime observation of attempted networking and local writes.
3. Operation with outbound networking blocked.

Passing one check does not establish the others. Offline operation alone does not
prove that no network attempts occurred. Finite tests must not be presented as
absolute privacy guarantees.

## 7. Native macOS first, credible Linux path

Swift owns macOS interaction, including microphone capture and text delivery.
Rust owns the server, inference worker, and CLI. The application and CLI are sibling
clients of the server; inference uses an existing speech-recognition library.

The MVP targets macOS on Apple Silicon. Preserve a credible Linux path for the
non-macOS components without building a Linux desktop application or a general
inference-engine plugin framework for the MVP.

## Governance

These principles were explicitly agreed to establish the project's privacy,
delivery, and process-isolation boundaries before implementation.

Changes to their meaning require explicit project-owner agreement. Record the
date and rationale of an amendment here. Do not silently weaken a principle to
match existing code; identify the conflict and resolve it explicitly.

Amended 2026-10-27: the owner agreed to isolate inference specifically and use
`sandbox-exec` as the initial macOS mechanism. Section 5 now requires enforced
network isolation with fail-closed startup, strengthening offline behavior beyond
process separation. This records a requirement and implementation direction, not
evidence of macOS enforcement; the mechanism and its limitations live in the
technical design.

Implementation plans and reviews must identify relevant principles and the
evidence needed to check them. Document unverified behavior and platform-testing
limitations rather than treating a written policy as executable enforcement.

## Document ownership

- This constitution owns the governing commitments.
- The README owns the product introduction and implemented-versus-intended status.
- The domain glossary owns authoritative terminology.
- The MVP PRD owns user scenarios, scope, exclusions, and acceptance criteria.
- The technical design owns protocols, paths, lifecycle details, and model pins.
- Repository guidance owns developer commands and working conventions.

Concrete choices such as the recording-duration limit, single-request policy,
worker idle behavior, socket protocol, and model revision belong in the product
and technical designs rather than being duplicated here.
