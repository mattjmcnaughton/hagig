# Rust backend guidance

Read the root guidance, [constitution](../docs/CONSTITUTION.md) and
[technical design](../docs/technical/tdds/01-mvp.md) first. This is the issue #2
scaffold, not a working transcription application or server.

## Boundaries and scope

- One package, shared library and scaffold executable. Do not split crates by
  process. Swift owns native macOS interaction; Rust owns portable backend work.
- `launcher` is the constructor-injected platform effect boundary; `supervisor`
  owns the child and reap. The future request layer owns protocol/state and the
  returned private pipes. Keep request admission, generations, cancellation and
  result delivery out of the launcher. They are not implemented in this ticket.
- Inference-only external-network isolation MUST be enforced before native/model
  loading. Linux will use a network namespace; macOS initially sandbox-exec
  (deprecated, requiring explicit validation). Installer networking stays outside
  the worker. No unrestricted fallback, disable-sandbox flag or environment bypass.
- `PlatformLauncher` currently refuses ALL launches. Test-only unrestricted
  launchers live in `tests/`, never as production feature flags or CLI options.
  A trait contract alone does not prove sandbox enforcement.
- The launch adapter must sanitize environment/descriptors and suppress native
  diagnostics. Never log audio, transcripts, vocabulary, paths or raw OS errors.
- Explicit `stop` reports cleanup failures; Drop is best-effort. Immediate kill
  and reap are scaffold behavior, not the future graceful cancellation protocol.
  No descendant processes are supported. OS kill/wait latency is not bounded by
  this synchronous scaffold; asynchronous deadlines/escalation are later work.

## Dependency approval (mandatory)

Ask the owner BEFORE introducing any dependency outside: tokio (only the minimal
needed features), serde, serde_json, clap, toml, either rustix OR nix only when
standard APIs are insufficient (never both), tempfile for tests, and the existing
pinned sherpa-onnx candidate subject to its adoption gate. Approval is not a reason
to add an unused dependency. No DI framework or async-trait crate. Additional
download/checksum/audio libraries and development/build tools are NOT preapproved;
ask before adding or installing them. Standard Rust tools and the discussed just
conventions are allowed. Pin toolchain and lockfile; review transitive dependencies,
build scripts, native loading and automatic download behavior before adoption.

Current review: zero external crates, transitive crates, Cargo build scripts or
native inference libraries. Only Rust std and its platform runtime are used.
Tests execute system `/bin/sh` builtins and `/bin/kill -0` (existence observation);
they do not download models, use credentials or open network connections. These
fixtures are NOT evidence of network isolation or dependency privacy adoption.

## Developer commands

Run from `backend/`, so rustup selects `rust-toolchain.toml` (Rust 1.90.0 plus
rustfmt/Clippy). Track `Cargo.lock` even with no external dependencies. Build output
is ignored by this directory's `.gitignore`.

| Recipe | Equivalent standard Rust commands |
| --- | --- |
| `just build` | `cargo build --locked --all-targets` |
| `just fmt` | `cargo fmt --all` |
| `just fmt-check` | `cargo fmt --all -- --check` |
| `just lint` | `cargo clippy --locked --all-targets -- -D warnings` |
| `just test` | `cargo test --locked --all-targets` then `cargo test --locked --doc` |
| `just ci` | fmt-check, lint, test in that order |

Borrow only rasm-tui's constructor-injected trait and fmt/lint/test/ci recipes,
not its AWS/TUI dependencies, fake production repository or release pipeline.
Integration tests use controlled child processes through the public launch and
supervision APIs. Keep tests observable: private round-trip bytes, safe launch
failure, refusal without isolation, and child termination/reaping. No model assets
are required. Future cancellation tests must reject late/stale results, not merely
assert mock call order.

## Evidence and authorization

`.github/workflows/rust-checks.yml` defines Linux x86-64 and macOS 15 Apple Silicon
jobs, asserts the native Rust host, and runs the equivalent commands above with
read-only permissions, a SHA-pinned checkout and 15-minute job bounds. The runner
label is OS-major-pinned, not an immutable VM image. No workflow dispatch or release
pipeline is included. A workflow file is NOT evidence that a remote job ran.

Record actual executed commands, host/toolchain, results and limitations here.
Do not turn source inspection or local Linux checks into macOS/native isolation
claims. Issue implementation does not authorize commit, push, PR creation,
workflow dispatch, merge, deployment or installing unapproved tools. Obtain the
owner's concrete authorization for those actions first.

Local evidence (2026-10-27, Linux orb, x86_64-unknown-linux-gnu, rustc 1.90.0):

- `cargo fmt --all -- --check`: passed.
- `cargo clippy --locked --all-targets -- -D warnings`: passed, no warnings.
- `cargo test --locked --all-targets`: 5 integration tests passed; no unit tests.
  Checks include private IPC, repeated launch after reap, safe spawn failure,
  invalid-pipe cleanup, live-child Drop cleanup, and production refusal even with
  a purported bypass flag/environment setting. Process-existence observation has
  a positive live-child control and verifies absence after reap.
- `cargo test --locked --doc`: passed, 0 doctests.
- `cargo build --locked --all-targets`: passed.
- `cargo test --locked --test worker_boundary --quiet`: passed 10 additional runs.
- `cargo tree --locked` and Cargo metadata: only hagig, dependencies empty.
  `ldd target/debug/hagig`: system libgcc_s, libc and ELF loader; no inference libs.

At this initial local-validation checkpoint, remote Linux and Apple Silicon
execution had not run. The PR's exact-head Rust checks and their logs are the
authoritative remote evidence; inspect both host assertions and executed test
steps, not only a green rollup. The just command itself (not installed here), real
inference, Linux namespaces and macOS Seatbelt remain unverified by these checks.

The owner subsequently authorized one scaffold commit, branch push, PR creation,
automatic CI, and rebase-merge/remote-branch deletion only after actual Linux and
Apple Silicon checks pass and issue #2 acceptance is met. This is not permission
for manual workflow dispatch, releases or deployment. The current policy baseline
is incorporated from PR #11. Root docs and other threads' work remain untouched.
