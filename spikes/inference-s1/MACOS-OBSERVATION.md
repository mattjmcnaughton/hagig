# #6 macOS runtime observation (D6): preregistration

Evidence level 2 of constitution §6 only: **runtime observation of attempted
networking and local writes** by the real inference worker on one GitHub-hosted
Apple Silicon runner. It is not source inspection (level 1), not blocked-network
operation (level 3, already shown for Required by #5), not a privacy certificate
and not inference adoption. Linux strace observations are in
[FINDINGS.md](FINDINGS.md) §"Observed network/write behavior" and #9; they are
not macOS evidence.

Registered before the first run, under owner decision D6 (2026-11-09): one finite
experiment, one dedicated branch/PR, built-in macOS tools, synthetic input only.

## Claims under test

For the inference worker process chain (`sandbox-exec` in Required, then
`hagig-worker` bootstrap, then exec-replaced `hagig-inference-worker`), during
the existing `backend/tests/native_speech.py` real lifecycle (speech, warm
reuse, silence, busy, active cancel, crash, recovery, stop) with
`backend/tests/fixtures/speech.wav`:

1. **Required (default)**: count network attempts (socket/connect/bind/listen/
   accept/send/recv syscalls), writable file opens and file-mutating syscalls,
   and Seatbelt denial reports.
2. **Disabled (explicit `network_isolation='disabled'`)**: the same counts. No
   OS network block exists in this mode, so these attempts would succeed.

Prior expectation (from Linux traces and source inspection, NOT assumed): zero
network syscalls, zero writable opens or mutations, writes only to the private
stdout pipe (fd 1), and zero Seatbelt denials. Whatever is observed is reported
as observed; a nonzero count is a finding, not a reason to rerun.

## Observers (built-in only; `sudo` for read-only tracing)

- **Primary:** `fs_usage -e -w -f filesys -f network -f exec lsof pgrep sudo nettop`,
  system-wide (kernel ktrace), post-filtered by process name. A
  `buffer overrun` message invalidates that session.
- **Secondary:** unified log (`log show --style ndjson`) for Seatbelt denial
  reports and for any log entries emitted by worker processes; `lsof -F`
  descriptor snapshots of the worker every 0.5 s; `nettop -L 0 -s 1 -n -x`
  socket/flow samples. Each secondary observer counts only if its own positive
  control below was captured.
- Host facts recorded read-only: `sw_vers`, `uname`, `csrutil status`, image
  version, tool SHA-256s. No SIP, TCC, security-policy or product Seatbelt
  profile change; no new dependency, tool or pin.

## Positive controls

A synthetic std-only probe (`backend/tests/fixtures/observation_probe.rs`,
compiled with the pinned rustc) makes one loopback TCP connect and one loopback
UDP bind/send to a listener owned by the driver, creates and writes one new file
recording those outcomes, holds both for 1.5 s, then exits.

- **Ordinary child, every session:** copies named `hg6-lead` and `hg6-trail` run
  directly before and after the workload, inside the same trace. Each must show
  a successful connect plus a writable open of its own file and a write to that
  descriptor, else the whole session is `NOT OBSERVED / UNPROVEN`.
- **Same launch path:** the probe temporarily replaces the copied
  `Contents/Helpers/hagig-inference-worker`; the real `hagig __serve` then
  launches it through the production launcher (Required: `sandbox-exec` with the
  embedded profile, then the real bootstrap's exec; Disabled: the bootstrap
  directly) for one `hagig transcribe speech.wav`, which must fail. Expected:
  Required connect denied (EPERM/EACCES) yet traced at `socket` or `connect`,
  plus the traced file write;
  Disabled connect succeeds (listener accepts) and the write is traced. The
  original helper is restored and its SHA-256 rechecked before real sessions.
  Seatbelt denial reports are expected only in the Required control; nettop
  flows only where the connect succeeds.

Session order: Required launch control, real Required, real Disabled, Disabled
launch control. Each session starts its own tracers, waits 3 s, runs the lead
control, the workload and the trail control, waits 2 s, then stops tracers.

## Exact commands (job `macos-runtime-observation` in `rust-checks.yml`)

Runs only for `pull_request` events of this PR's same-repository head branch
`user/issue-6-macos-runtime-observation`; skipped on every other branch and on
main. `macos-15`, Xcode 16.4, pinned Rust 1.90.0, 20-minute hard timeout,
read-only token, SHA-pinned actions. From `backend/`:

```sh
# before any acquisition: one traced session with only the two ordinary controls
python3 tests/observe_macos_runtime.py --smoke --trace "$RUNNER_TEMP/hagig-issue6-trace-smoke" --evidence "$evidence"
bash tests/prepare_macos_candidate.sh   # pinned archive SHA256, allowlisted extraction, network-denied build
XDG_DATA_HOME="$root/data" XDG_CONFIG_HOME="$root/install-config" \
  "$root/Contents/Helpers/hagig" model install parakeet-tdt-0.6b-v2-int8-v1
# independent size/SHA-256 check of all five installed assets (exercise_macos_candidate.sh logic)
python3 tests/observe_macos_runtime.py --root "$root" --trace "$RUNNER_TEMP/hagig-issue6-trace" --evidence "$evidence"
# re-verify native helper/library and all five installed model hashes afterwards
```

The smoke session compiles the probe and proves fs_usage capture and the
parser before any download, so a tracer or parser failure costs no
acquisition. `native_speech.py` and `speech.wav` are reused unchanged.

## Validity gates (job fails only if the experiment is invalid)

- every session: tracer started and stopped cleanly, no overrun, both ordinary
  controls captured with listener-side ground truth;
- launch controls: CLI failure, probe file present with the expected connect
  outcome, and the attempt plus write traced under the worker's names;
- real sessions: `native_speech.py` exits 0 with its stop/reap pass line, and
  the trace shows the worker opening `encoder.int8.onnx` (the tracer saw the
  real worker, not an empty name filter);
- a session whose service stop is unproven ends the run (no further sessions);
- helper restored byte-identical; installed model hashes unchanged afterwards.

Observed worker counts never fail the job; they are the result to inspect.
An invalid run is investigated, never manually rerun or dispatched (D14); any
fix is a new pushed commit recorded below with its reason.

## Costs, retention and cleanup

One macOS-15 job, about 10 minutes expected. Reacquires the same pinned assets
(about 3.15 GB) only through the existing preparation script and explicit
installer. Raw traces stay on the runner in `$RUNNER_TEMP/hagig-issue6-trace`
and are deleted. Cleanup gate: the driver writes a completion marker only after
every server is stopped and reaped; disposal requires the marker (or proof that
no session started) and no live helper process, then removes model data, native
files, archive and raw traces. Upload only bounded synthetic, content-free text
summaries (syscall/errno counts, descriptor numbers, synthetic paths), 7-day
retention. No model or native bytes are uploaded.

## Limits registered in advance

- fs_usage does not trace `connectx`, `sendmsg_x`, NECP/Skywalk channel calls or
  Mach IPC, so networking delegated to another daemon (for example via XPC) or
  done through those calls is not observed by the primary tracer. nettop and
  lsof partially cover sockets/flows; nothing here covers Mach IPC.
- `mmap`-based writes, writes by other processes on the worker's behalf and
  unified-log persistence through `logd` are not file writes by the worker; log
  entries are counted separately.
- fs_usage excludes `sh`, `zsh` and similar shells by default; none are in the
  worker chain. Event names come from kernel execnames and may be truncated.
- One runner, one finite synthetic workload, CPU provider. Not physical-Mac,
  user-audio, other-model or every-code-path evidence. Finite observation is not
  proof that no attempt can occur.

Results will be appended below after inspection of the run.
