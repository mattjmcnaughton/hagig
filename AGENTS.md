# Repository guidance

Read [the constitution](docs/CONSTITUTION.md) before planning, implementing, or reviewing
changes. It contains the project's agreed commitments, not a claim of implemented
functionality. Keep proposals and unverified behavior distinct from working
features, and identify any conflict with the constitution rather than silently
changing its meaning.

## Dependency boundaries

Inject external effects at meaningful ownership boundaries through explicit
constructor or function inputs. Use Rust traits or Swift protocols when a
behavioral contract warrants them, closures for simple effects, and concrete types
otherwise. Do not introduce an interface for every type or speculative future
implementations. Keep dependency wiring explicit; no service locators or DI
containers. This is not an inference-engine plugin framework.

Test observable behavior through public interfaces, not mock call order. Controlled
substitutes help exercise failures and races but do not establish real platform,
inference, or privacy behavior; retain integration evidence for those boundaries.

## Dependency approval

Ask the owner before adding dependencies outside the agreed starting set:
`tokio` (only needed features), `serde`, `serde_json`, `clap`, `toml`, either
`rustix` or `nix` where standard APIs are insufficient (not both), `tempfile`
for tests, and the existing pinned sherpa-onnx inference candidate subject to its
adoption gate. No dependency-injection or async-trait crate is needed initially.
Download, checksum, WAV/resampling libraries and additional development/build
tools have not been selected; request approval before introducing them. Review
transitive dependencies and native build/download behavior as part of adoption.

Owner-approved #9 experiment (2026-11-08): the pinned candidate's macOS
build-only zip→nix closure may coexist with rustix for bounded Apple Silicon
experiments. This is not permission to add runtime nix, change pins, invoke the
upstream native downloader, or claim inference adoption. The four exact installer
crates approved for #9 are recorded in backend guidance.

Native macOS code and its render/test commands live in `clients/macos/`; follow
its scoped [guidance](clients/macos/AGENTS.md). Use the same SwiftUI views in the
shell and native screenshot harness. Prove the Ready render/artifact path on a
GitHub-hosted Mac before collecting representative states. Linux static checks
are not native build, render, interaction or physical-Mac acceptance evidence.
Pushing and manually dispatching remote workflows require explicit permission.
