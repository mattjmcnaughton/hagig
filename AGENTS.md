# Repository guidance

Read [the constitution](docs/CONSTITUTION.md) before planning, implementing, or reviewing
changes. It contains the project's agreed commitments, not a claim of implemented
functionality. Keep proposals and unverified behavior distinct from working
features, and identify any conflict with the constitution rather than silently
changing its meaning.

## Dependency boundaries

Inject external effects at meaningful ownership boundaries through explicit
constructor or function inputs. Use Python `Protocol`s or Swift protocols when a
behavioral contract warrants them, closures for simple effects, and concrete types
otherwise. Do not introduce an interface for every type or speculative future
implementations. Keep dependency wiring explicit; no service locators or DI
containers. This is not an inference-engine plugin framework.

Test observable behavior through public interfaces, not mock call order. Controlled
substitutes help exercise failures and races but do not establish real platform,
inference, or privacy behavior; retain integration evidence for those boundaries.

## Dependency approval

Ask the owner before adding dependencies outside the agreed starting set:

- Python, managed by uv: `fastapi`, `uvicorn`, `pydantic`, `typer`, `httpx`,
  `numpy` and `structlog`; stdlib `tomllib` for configuration.
- Inference: `transformers` and `torch` for Qwen3-ASR, and `mlx` and
  `mlx-whisper` for Whisper (Apple Silicon only), with their locked
  transitives, subject to the adoption gate in the technical design.
- Swift: swift-server `AsyncHTTPClient` for HTTP over the Unix socket.
- Development: `uv`, `ruff`, `ty`, `pytest`, `just`, and `copier` for generating
  `backend/` from the owner's template.

No dependency-injection framework. Audio/resampling libraries and other
development or build tools have not been selected; request approval before
introducing them. Review transitive dependencies, native wheels and
download/telemetry behavior as part of adoption.

Native macOS code and its render/test commands live in `clients/macos/`; follow
its scoped [guidance](clients/macos/AGENTS.md). Use the same SwiftUI views in the
shell and native screenshot harness. Prove the Ready render/artifact path on a
GitHub-hosted Mac before collecting representative states. Linux static checks
are not native build, render, interaction or physical-Mac acceptance evidence.
Pushing and manually dispatching remote workflows require explicit permission.
