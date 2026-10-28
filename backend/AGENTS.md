# Rust backend guidance

Read the root guidance, [constitution](../docs/CONSTITUTION.md) and
[technical design](../docs/technical/tdds/01-mvp.md) first. This contains the issue
#2 scaffold and issue #4 Linux launch adapter, not a transcription app or server.

## Boundaries and scope

- One package, shared library and scaffold executable. Do not split crates by
  process. Swift owns native macOS interaction; Rust owns portable backend work.
- `launcher` is the constructor-injected platform effect boundary; `supervisor`
  owns the child and reap. The future request layer owns protocol/state and the
  returned private pipes. Keep request admission, generations, cancellation and
  result delivery out of the launcher. They are not implemented in this ticket.
- Inference-only external-network isolation defaults to Required; an explicit
  Disabled startup mode is a supported product opt-out, not an automatic fallback
  or development-only exception. Required enforces before native/model loading
  or refuses; Linux uses user/network namespaces, macOS initially sandbox-exec
  (deprecated, requiring validation). Disabled makes no network-block claim.
  Both modes retain offline/no uploads/no telemetry, process separation and all
  launch hygiene. Installer networking remains outside the worker.
- `PlatformLauncher::new(WorkerExecutable::new(absolute_path)?)` selects the
  configured Linux adapter with Required default. Explicitly select
  `.with_network_isolation(NetworkIsolation::Disabled)` before startup to opt out.
  `.network_isolation()` plus Display reports only the content-free selection,
  not enforcement evidence. Only the trusted target and typed mode are configurable,
  not arguments, shell commands, environment or arbitrary policy. TOML/server
  parsing/status integration remains future work. `unconfigured()` and platforms without
  an integrated adapter fail closed. The scaffold executable stays unconfigured.
  Test-only unrestricted launchers live in `tests/`, never production options.
- The target must be a trusted small Rust bootstrap, not linked inference code.
  It flushes `HAGIG-WORKER-READY-v1\n` within five seconds, then begins the future
  worker protocol. Adapters consume only this fixed ACK, not protocol bytes.
  No inference library/model loading is allowed before this bootstrap boundary.
  Required Linux namespace setup precedes even target exec/dynamic loading. macOS adapter
  integration and its native proof are independently owned by issue #5.
- The launch adapter must sanitize environment/descriptors and suppress native
  diagnostics. Never log audio, transcripts, vocabulary, paths or raw OS errors.
- Explicit `stop` reports cleanup failures; Drop is best-effort. Immediate kill
  and reap are scaffold behavior, not the future graceful cancellation protocol.
  No descendant processes are supported. OS kill/wait latency is not bounded by
  this synchronous scaffold; asynchronous deadlines/escalation are later work.
- Unsafe code is denied crate-wide, with local exceptions only at Linux's three
  audited sites: pre_exec, unshare_unsafe, and enumerated BorrowedFd construction.
  No module-wide unsafe allowance. The callback uses syscalls, stack buffers and bytes
  allocated before fork: unshare, uid/gid maps, no_new_privs, and /proc/self/fd
  enumeration to mark all descriptors >=3 CLOEXEC. Disabled bypasses only namespace
  creation/maps; no_new_privs, descriptor/environment/cwd/pipe/ACK hygiene remains.
  Do not add allocation, locks,
  std I/O, logging or panics there. CLOEXEC preserves std's exec-error pipe until
  exec while closing preconnected sockets before target/native loading.

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

Issue #4 dependency review: standard Rust has no unshare or post-fork FD
enumeration API, so Linux alone uses approved `rustix = 1.1.6` with only
std/fs/process/thread/event features. Do not also add nix. Active x86-64 Linux
transitives are bitflags 2.13.2 and linux-raw-sys 0.12.1 (no build scripts); the
lockfile also resolves inactive conditional libc/errno/Windows packages. No rustix
net feature, native inference library, external compiler or artifact downloader
was added. Reviewed rustix's build.rs: target/compiler feature detection using
rustc metadata probes in OUT_DIR, then probe-file cleanup; no network/download
or native compilation path. Used rustix paths are syscall wrappers; bitflags and
linux-raw-sys supply flags/generated ABI definitions. This source/build-path review
is not an exhaustive dependency privacy certification for every feature/target.

Tests use `/bin/sh` builtins and `/bin/kill -0` for scaffold fixtures. Linux tests
compile a std-only worker using the pinned rustc into a test-owned Cargo temporary
directory, then remove it and PID-only observation files on exit. The probe is not
a production executable/feature. TCP endpoints are controlled IPv4/IPv6 loopback
listeners, never model downloads, credentials or general internet services.

## Developer commands

Run from `backend/`, so rustup selects `rust-toolchain.toml` (Rust 1.90.0 plus
rustfmt/Clippy). Track `Cargo.lock` even with no external dependencies. Build output
is ignored by this directory's `.gitignore`.

| Recipe | Equivalent standard Rust commands |
| --- | --- |
| `just build` | `cargo build --locked --all-targets` |
| `just fmt` | `cargo fmt --all` then `rustfmt --edition 2024 tests/fixtures/linux_worker.rs` |
| `just fmt-check` | `cargo fmt --all -- --check` then `rustfmt --edition 2024 --check tests/fixtures/linux_worker.rs` |
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

Historical scaffold evidence (#2, 2026-10-27, Linux orb, x86_64-unknown-linux-gnu,
rustc 1.90.0, before adding the Linux adapter/dependency):

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

## Linux adapter evidence (#4)

Run `cargo test --locked --test linux_isolation -- --nocapture` on a capable host
for both explicit modes through PlatformLauncher and Supervisor. The required
enforcement test fails UNSUPPORTED if namespaces/proc facilities or host IPv6
are unavailable; it does NOT count refusal or disabled success as enforcement.
Do not change host sysctls/AppArmor/seccomp policy to manufacture a pass.

The same worker connects to the same outside listeners before and after isolated
runs. Checks require a different network namespace from the first worker-main
instructions, IPv4 ENETUNREACH, and IPv6 EADDRNOTAVAIL or ENETUNREACH (no source
address/route in the fresh namespace), never an arbitrary failed connection.
It deliberately leaks a preconnected inheritable socket in the unrestricted
control and requires its absence under isolation; it also checks empty environment,
root cwd, no_new_privs, protocol bytes immediately after ACK, live-child kill/reap,
Drop cleanup and relaunch. A captured subprocess asserts that a diagnostic canary
emitted by the unrestricted control never escapes the production launcher's stderr
suppression. Bad/EOF/stalled ACKs must fail and reap within the ACK
deadline. A subprocess in an unmapped user namespace triggers a REAL kernel
denial of nested user-namespace creation; the target must never execute.

This orb's Linux 6.1.158+ allows user/network namespaces and IPv6 loopback.
Initial probe observed isolated IPv4 errno 101 and IPv6 errno 99; independent
`unshare -Urn` socket checks confirmed those kernel reasons. The initial test's
expectation that both families returned errno 101 was corrected, not treated as
a passing run. The actual unsupported-host case remains host-dependent; the
unmapped-parent test establishes fail-closed handling of real kernel denial.

A network namespace is not filesystem/process confinement, protection against a
malicious same-user process, prevention of filesystem-accessible proxy services,
or proof of absence of networking attempts. Tests intentionally attempt connects.
Inference/model integration, DNS-specific probes, descendants and async shutdown
are not implemented here. At the initial checkpoint new remote Linux/macOS runs
were unverified and #4 publication was not authorized. Owner D2 subsequently
authorized commit/push/PR, automatic native CI and rebase-merge/branch deletion
only after actual review-suite, resolve-review and exact-head CI gates pass.
No manual dispatch, release/deployment, host-policy weakening or protection bypass.

Implementation-checkpoint checks (recorded 2026-10-27, Linux, pinned Rust 1.90.0):

- Cargo fmt check and standalone fixture rustfmt check: passed.
- `cargo clippy --locked --all-targets -- -D warnings`: passed.
- `cargo test --locked --all-targets -- --nocapture`: 8 integration tests passed
  (2 Linux boundary tests, 6 scaffold tests), no ignored tests; nested subprocess
  checks exercise captured diagnostics and actual kernel denial.
- `cargo test --locked --doc`: passed, 0 doctests.
- `cargo build --locked --all-targets`: passed.
- `cargo tree --locked`: hagig -> rustix -> bitflags/linux-raw-sys only on this host.
- Four observed explicit stop/relaunch rounds denied IPv4 with errno 101 and IPv6
  with errno 99; additional live-child Drop/reap rounds passed. Stalled startup
  failed safely and was reaped after about 5.006 seconds. Missing executable,
  bad ACK, EOF, and real namespace denial returned safe errors; no fallback ran.
- Captured log contains no emitted worker diagnostic canary. Reviewable local log:
  `.amp/in/artifacts/issue-4-linux-verification.txt` at repository root.

API integration order: issue #4 lands shared configuration/ACK and Linux dispatch;
issue #5 then adds its owned macOS module, dispatch and any needed widening of
the same pinned rustix target configuration. Until then, configured non-Linux
launches remain refused and tested as such. Do not import independently owned
unpushed macOS work without owner integration approval.

Review resolution (2026-10-28): six actual review-suite skill lenses reviewed the
complete task diff including new files. Seven warnings, no critical/nits: six
dependency/I/O/tool inventories documented as intentional scope; one verified ACK
test gap addressed. Existing tests now also exercise a correct prefix/wrong
version suffix, truncated-prefix EOF, fragmented successful ACK plus immediate
protocol, and a four-second prefix drip that must not reset the total five-second
deadline. Targeted Linux tests passed, including reap/recovery. In disposable
copies, first-byte-only ACK validation failed with unexpected launch success;
per-read deadline reset failed the <7s bound. Neither mutation touched production
source; scratch copies were removed. Final combined checks and exact-head remote
native CI remain separate gates, not substituted by the suite. Local ignored
current-capture plan/diary/review-resolution records are not shipped source.

### Hosted Linux support/evidence checkpoint (2026-10-28)

There is no 22.04-only product ceiling: explicit Disabled is supported on modern
Ubuntu; Required still enforces or refuses without retry. CI separately labels
22.04 capable-host enforcement evidence, 24.04 disabled/refusal evidence, and Mac
portable shared checks (not yet Seatbelt proof). Both Linux jobs build/lint the
whole package; 24.04 executes the full disabled hygiene/failure contract, required
enforcement-or-refusal classification, real unmapped-userns denial and portable
tests. It does NOT claim a passing full required-network gate. Diagnostics assert
that the observed 24.04 mapped probe is denied; a policy change needs investigation,
not an automatic status reinterpretation.

The 22.04 enforcement host is available but deprecated since 2026-09-17 and retires
2027-04-17, with March/April brownouts. Replace that evidence host before then with
independently verified capability and the full unchanged required-network gate.
This is a CI-evidence prerequisite, not an installer or product OS maximum.
Do not disable AppArmor, change sysctls, add privileged containers, or count
unsupported acceptance probes as green enforcement evidence.
See the [official retirement notice](https://github.com/actions/runner-images/issues/14254).

At comparison head `8f79248bf8bb09a0fd56d883086e78334e7d3e35`, the
[PR 22.04 job](https://github.com/mattjmcnaughton/hagig/actions/runs/40688513118/job/122817010028)
and [push 22.04 job](https://github.com/mattjmcnaughton/hagig/actions/runs/40688506386/job/122816985848)
actually ran build, formatting, Clippy, both Linux isolation tests, six scaffold
tests, and doctests successfully, with zero ignored tests. Independent userns
and mapped user/network probes both returned 0. Kernel 6.8.0-1064-azure, pinned
Rust 1.90.0 x86_64-unknown-linux-gnu. Setup logs identify ubuntu-22.04 image
20261012.322.1; ImageVersion environment metadata reports 20261023.322.3. These
different metadata values are recorded as observed, not reconciled by guessing;
the label is OS-version-pinned, not an immutable VM image. AppArmor restriction
value 0 was observed on these hosts, never changed by the workflow.

The [same-head 24.04 job](https://github.com/mattjmcnaughton/hagig/actions/runs/40688513118/job/122817010345)
is explicitly NOT a passing isolation host: unrestricted IPv4/IPv6 controls
succeeded, configured launch failed closed, and independent `unshare` failed
writing `/proc/self/uid_map` with EPERM. Userns-only control returned 0, mapped
user/network control returned 1. Kernel 7.0.0-1017-azure; setup image
20261025.353.1, ImageVersion metadata 20261026.354.1. Restriction value 1 observed;
the exact responsible LSM rule/first failing production syscall was not uniquely
established. This is historical required-mode refusal evidence, NOT a passing
24.04 network-enforcement test. The subsequently accepted explicit-mode contract
adds a supported disabled path; it does not reinterpret that historical failure.

Read-only namespace diagnostics now run on Linux after both successful and failed
gates, report both independent probe statuses and expected capability/refusal, and print
specific kernel/image/policy observations only. They read no secrets and change
no host security policy. Native Apple Silicon shared/scaffold checks also passed
at the comparison head; this is not macOS Seatbelt/inference evidence. The rejected
22-only pin was never published. Final explicit-mode source and transferred policy
docs require a new complete-task review/resolution and actual exact-head native CI
before merge. No profile installation, sudo, host policy change or new dependency.
