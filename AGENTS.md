# Repository guidance

Read [the constitution](docs/CONSTITUTION.md) before planning, implementing, or reviewing
changes. It contains the project's agreed commitments, not a claim of implemented
functionality. Keep proposals and unverified behavior distinct from working
features, and identify any conflict with the constitution rather than silently
changing its meaning.

## Dependency approval

Ask the owner before adding dependencies outside the agreed starting set:
`tokio` (only needed features), `serde`, `serde_json`, `clap`, `toml`, either
`rustix` or `nix` where standard APIs are insufficient (not both), `tempfile`
for tests, and the existing pinned sherpa-onnx inference candidate subject to its
adoption gate. No dependency-injection or async-trait crate is needed initially.
Download, checksum, WAV/resampling libraries and additional development/build
tools have not been selected; request approval before introducing them. Review
transitive dependencies and native build/download behavior as part of adoption.

Native macOS code and its render/test commands live in `clients/macos/`; follow
its scoped [guidance](clients/macos/AGENTS.md). Use the same SwiftUI views in the
shell and native screenshot harness. Prove the Ready render/artifact path on a
GitHub-hosted Mac before collecting representative states. Linux static checks
are not native build, render, interaction or physical-Mac acceptance evidence.
Pushing and manually dispatching remote workflows require explicit permission.
