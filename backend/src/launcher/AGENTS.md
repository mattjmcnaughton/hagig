# Platform isolation adapters

Follow backend guidance and the constitution. This directory is the OS effect
boundary, not an inference engine, request router or native macOS UI. Linux and
shared dispatch/configuration belong to issue #4; macOS files and its dedicated
workflow belong to issue #5. Do not overwrite another adapter's shared changes.

## macOS bootstrap

- `macos.rs::launch(&WorkerExecutable, NetworkIsolation)` honors the selected
  product mode. Required is the default: fixed absolute `/usr/bin/sandbox-exec`
  with embedded `seatbelt-v1.sb`. The tool is deprecated; this policy denies
  `network*`, not filesystem access/process creation. Explicit Disabled directly
  launches the trusted bootstrap, with NO OS-network-block claim. It is never an
  automatic fallback from Required failure. No configurable tool/profile/arbitrary
  arguments/environment or shell wrapper is exposed. Supervision still forbids
  surviving descendants. No proposed TOML/server parser is implemented here.
- `WorkerExecutable` identifies a trusted installed bootstrap, not an arbitrary
  inference plugin. It must flush exactly `HAGIG-WORKER-READY-v1\n` within five
  seconds before loading inference/model code; no inference startup constructors.
  The adapter consumes only this ACK, leaving later stdout for private IPC. Tool
  spawn alone cannot prove policy application/target exec; absent, partial,
  malformed or late ACK causes kill/reap and content-free WorkerNotReady in either
  mode. Tool spawn failures use mode-neutral SpawnFailed; no failure retries Disabled.
- In BOTH modes, environment is cleared, cwd is `/`, stdin/stdout are private pipes, stderr is
  null. A narrow audited Darwin FFI boundary enumerates the postfork child's FDs
  with `proc_pidinfo` into a fixed stack buffer, fails closed on error/full buffer,
  and marks every FD >=3 close-on-exec. Mark rather than close, preserving std's
  exec-error pipe. This is needed because Rust 1.90 std spawn does not set Darwin
  `POSIX_SPAWN_CLOEXEC_DEFAULT`. Use approved rustix 1.1.6, not handwritten
  poll/fcntl/getpid ABIs. macOS needs only its std/event/process features; #4
  owns the same version's Linux manifest. Coordinate target-specific manifest
  integration after #4, never introduce both rustix and nix.
- ABI/source references for residual enumeration: Apple OSS xnu
  `bsd/sys/proc_info.h` and `libsyscall/wrappers/libproc/{libproc.h,libproc.c}`.
  `proc_pidinfo` is a direct `__proc_info` wrapper, without allocation or locks;
  postfork code must remain syscall-only. Recheck these assumptions on OS updates.
- `Supervisor` and its unchanged Child/private-pipe contract remain the ownership
  boundary. Kill/wait OS latency is not bounded by the startup polling deadline.

## Unsafe-policy reconciliation

Issue #4 landed crate-level `#![deny(unsafe_code)]`; an inner allow cannot override
the earlier forbid policy. No crate-wide allow or additional shared policy change
is needed for macOS. The adapter has no file/module-wide
unsafe allowance. Only four individual documented sites carry `#[allow(unsafe_code)]`:
the empty system-library link declaration, bootstrap registration, libc libproc
call and raw-descriptor borrow. No handwritten production C signature/struct
remains; the empty extern block only links system `libproc`.

Approved safe wrappers inspected in rustix 1.1.6:

- `src/event/poll.rs`: `poll(&mut [PollFd<'_>], Option<&Timespec>) -> io::Result<usize>`;
  used by shared `launcher.rs::await_ready(&mut Child) -> std::io::Result<()>`
  without unsafe. Both adapters use the same exact ACK/deadline implementation.
- `src/io/fcntl.rs`: `fcntl_setfd<Fd: AsFd>(Fd, FdFlags) -> io::Result<()>`;
  used for CLOEXEC. Tests use `fcntl_dupfd_cloexec` then clear CLOEXEC safely,
  rather than raw variadic fcntl. `fcntl_dupfd` itself is NOT exposed on Darwin.
- `src/process/id.rs`: `getpid() -> Pid`; no handwritten getpid declaration.

Residual unsafe in `macos.rs::bootstrap` remains necessary for this design:
`configure_descriptor_hygiene(&mut Command)` registers std's inherently unsafe
`CommandExt::pre_exec` callback. `sanitize_descriptors() -> std::io::Result<()>`
must enumerate the single-threaded child's actual FDs (a parent snapshot races)
and use `BorrowedFd::borrow_raw` on each live enumerated FD. Rustix's safe fcntl
wrapper requires that valid borrow; it cannot establish FD validity itself.
The callback must remain allocation/lock-free, including the wrappers it calls.

Rustix 1.1.6 has NO Darwin `proc_pidinfo`/FD-enumeration wrapper. Owner decision D1
approved macOS-only direct `libc = "=0.2.191"`, `default-features = false`, after
trusted-maintainer provenance verification. This is implemented in Cargo.toml
alongside the same pinned rustix; no nix. Inspected libc 0.2.191 exposes
`proc_pidinfo(c_int, c_int, u64, *mut c_void, c_int) -> c_int`, `proc_fdinfo`, and
`PROC_PIDLISTFDS` in `src/unix/bsd/apple/mod.rs`. These replace handwritten ABI/type/
constant maintenance, not unsafe buffer/callback/lifetime obligations.

The standalone synthetic `seatbelt_probe.rs` also has a test-only raw F_GETFD
declaration to observe deliberately CLOSED descriptor numbers; creating a
BorrowedFd for a closed FD would itself violate safety. This fixture is not linked
into the production library. Its declaration/call need the same explicit audit;
do not confuse them with a safe production FD operation.

## libc adoption record (D1)

- Provenance supplied and verified by the coordinating owner thread: official
  [rust-lang/libc](https://github.com/rust-lang/libc) repository, active under
  rust-lang; crates.io owner `rust-lang-owner`; Rust RFC 3119 identifies libc as
  an intentionally maintained official Rust-project artifact. Version 0.2.191 is
  non-yanked, licensed `MIT OR Apache-2.0`. Local downloaded manifest matches the
  repository/version/license. Reasonable provenance is not a security guarantee.
- Cargo.lock and the downloaded `.crate` archive SHA-256 both match the approved
  `65cd87c9a6d60536580b316ad985726104730a5151c99845f2490428ef91240a`.
- Source review: the Darwin `proc_fdinfo` layout, `PROC_PIDLISTFDS` and
  `proc_pidinfo` declaration above; package manifest/features and complete build.rs.
  The Darwin build path probes compiler/wrapper version and emits target cfgs.
  Other-target branches probe FreeBSD/emcc versions. No automatic download,
  network-client or native compilation path was found in that build script.
  This is scoped source inspection, not a whole-crate audit or runtime observation.
- libc declares OS bindings; it does not implement an inference runtime or load
  models. Its optional `rustc-std-workspace-core` dependency is inactive here.
  Dependency acquisition is a deliberate Cargo build operation outside the worker.
- Compared locked metadata against the same manifest with only rustix: adding
  direct libc adds **zero** package/version/checksum entries or active Darwin
  nodes. Active Darwin dependencies remain rustix 1.1.6, bitflags 2.13.2, errno
  0.3.14 and libc 0.2.191. Both direct edges disable default features; unified
  libc still has `std` through existing rustix, unchanged by the new direct edge.
  Lockfile also records inactive Linux/Windows packages from rustix; these are
  not newly activated by direct libc. Integration preserves #4's Linux-only
  stanza and lock entries; the added direct libc edge is macOS-only.
- `cargo check` and Clippy `--lib --tests --target aarch64-apple-darwin` passed
  with the typed-libc version against #4's exact shared deny/API files in a
  disposable integration tree. No native Mac linking or execution was performed.
  This preceded the mode API amendment. D2 now permits gated delivery after #4;
  it does not authorize manual dispatch or bypassing review/native evidence gates.

## Native proof commands and evidence

Run from `backend/` on macOS using pinned Rust 1.90.0:

```sh
cargo fmt --all -- --check
rustfmt --edition 2024 --check src/launcher/seatbelt_probe.rs
cargo build --locked --all-targets
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked --lib launcher::macos::tests -- --nocapture
cargo test --locked --all-targets
cargo test --locked --doc
```

The filtered test command must execute **three** tests, not zero. The tests compile
`seatbelt_probe.rs` using the pinned rustc into a private, exclusively created
temporary directory (removed by RAII). This probe is not shipped as an executable,
has no model/native inference/UI dependency, and receives synthetic commands only.
Positive controls use controlled listeners outside the sandbox on both loopback
families and must connect. Isolated attempts must report EPERM/EACCES, not merely
any connection failure. IPv6 unavailability is a failed gate, never a silent skip.
Native tests are designed to exercise default Required and explicit Disabled
through the real Supervisor: Required must deny both families; Disabled must connect without any network-block claim,
while preserving the same FD/env/cwd/private-pipe hygiene. A failing Required tool/
policy must return an error rather than trying Disabled. ACK refusal/reap runs in
both modes, including slow partial progress that catches per-byte deadline resets.
These native scenarios remain unexecuted until actual authorized Mac CI runs.
An intentionally inheritable high-numbered connected socket must be visible to
the positive control and absent in the isolated child. A dedicated test subprocess
injects sentinel/proxy environment without mutating the parallel test runner.
Private request/reply pipes and cwd are checked. Malformed policy, denied exec,
missing tool/worker and wrong/absent/partial ACK must fail closed. Synthetic PID
observation checks failed bootstraps are reaped, not just disconnected.

`.github/workflows/macos-seatbelt.yml` is path-filtered push/PR CI: macos-15 Apple
Silicon, Xcode 16.4 linker tools, pinned Rust, read-only token, SHA-pinned actions,
10-minute job bound and 5-day evidence retention. No manual dispatch. Runner labels
are not immutable images; the artifact records actual OS/build, image, arch, Rust,
Xcode, policy version/hash, sandbox tool hash and gate outcome. The tool has no
stable standalone version option; its OS build and binary hash identify it.
Only fixed versioned synthetic result lines are uploaded, not raw diagnostics,
paths to user assets, environment dumps or user content. An artifact may record
failure; inspect outcome plus all expected results, never equate upload with proof.

## Current limitations / integration

Post-integration local checks (2026-10-28, Linux orb, Rust 1.90.0): build, fmt,
standalone fixture fmt, Clippy and all ten Linux/shared tests passed, zero ignored;
doctests passed (zero). Darwin all-target cargo check and Clippy passed. Review-suite
ran all six actual lenses over the complete integrated diff/new files; no critical
findings. Resolve-review extracted the unchanged Linux ACK implementation into
the shared launcher for both adapters and added a full correct-prefix/wrong-version
ACK case in both Mac modes. Three dependency/test-I/O/artifact inventories are
intentional approved scope. Native execution is still pending; cross-checks are
not Mac linking, ABI or enforcement evidence.

Implementation is local pending reviewed publication and actual native CI. Issue
#4's amended policy/typed API landed in origin/main at f9a80ee and is integrated
with cfg-gated `mod macos` and `macos::launch(worker, self.network_isolation)`.
Owner authorized commit/push/PR and automatic native CI plus gated review/resolution
and merge. Linux formatting/type checks are not macOS enforcement evidence.
Unconfigured launchers remain fail-closed;
respect shared required/disabled behavior on unsupported OSes. The mode amendment
was explicitly accepted by the owner and root policy lands atomically with #4;
do not publish against the old policy. No broad bypass was inferred.

Prior local checks in the Linux x86_64 orb with Rust 1.90.0, before the mode API
amendment (do not infer these revalidated the revised typed seam):

- Baseline `cargo test --locked --all-targets`: five existing worker-boundary
  tests passed; `cargo test --locked --doc`: zero doctests, passed. These do not
  compile or execute the new cfg-macOS module on Linux.
- `cargo fmt --all -- --check`, explicit Rust 2024 rustfmt check of `macos.rs`
  (including its test module) and `seatbelt_probe.rs`, and baseline
  `cargo clippy --locked --all-targets -- -D warnings`: passed.
- In an ignored integration tree inside this checkout, using the exact shared
  `launcher.rs`/`lib.rs` downloaded from the issue #4 thread plus only the Mac
  dispatch integration above: `cargo check --locked --lib --tests --target
  aarch64-apple-darwin` and corresponding `cargo clippy ... -- -D warnings`
  passed. This checks target types/lints, NOT native linking, ABI or enforcement.
  The revised rustix-wrapper version was rechecked the same way. A countercheck
  with the actual baseline forbid policy rejects local unsafe allowances (E0453);
  the coordinated #4 deny policy accepts only the documented local exceptions.
- Standalone probe compiled for Linux and Darwin metadata. A scratch Linux
  controller exercised both positive TCP controls, pipe replies, inherited/closed
  descriptor detection, contaminated/clean environment detection and cwd. Passed;
  this validates fixture discrimination only, not the Mac launch adapter.
- Workflow shell blocks passed `bash -n`; new-file whitespace checks passed.
  actionlint/YAML parsers are not installed; none were installed without approval.

Even a passing native probe establishes only finite loopback TCP/pipe/hygiene
observations on that runner. DNS/UDP, real remote endpoints, actual inference,
dynamic model/library loading, app packaging and physical-Mac behavior remain
separate adoption gates. This policy does not prove no network attempts occurred,
general sandboxing, filesystem privacy or absence of diagnostic side effects.
