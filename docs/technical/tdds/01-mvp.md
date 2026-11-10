# Hagig private-alpha technical design

Status: copy-only alpha implementation design, not a working alpha. The native
synthetic shell exists; see [native guidance](../../../clients/macos/AGENTS.md).
The Python backend, REST API, real transcription, TOML integration, editable
review and local `.app` assembly described below are planned, not implemented.
Agreed scope is in the PRD; unimplemented details below remain proposals unless
explicitly identified as settled owner choices.

Read the [constitution](../../CONSTITUTION.md) and [MVP PRD](../../product/prds/01-mvp.md) first. This
document does not certify dependency privacy or model performance.

## 1. Architecture and ownership

```text
Swift macOS app ── HTTP/1.1 over Unix socket ──┐
                                               ├── Python server ── private pipes ── Python worker
Python CLI ────── HTTP/1.1 over Unix socket ──┘   (FastAPI, uvicorn)                    │
                                                                     transformers on PyTorch
                                                                     Qwen3-ASR
```

- **Swift app:** AppKit menu-bar Record/Stop lifecycle, permissions, microphone
  capture/conversion, in-memory editor and explicit current-device-only Copy.
- **Python server:** single-request admission, authoritative backend request state,
  configuration/model validation, audio buffering, worker supervision, and cancellation.
  It never imports the inference engine, PyTorch or model code.
- **Python worker:** inference only. Native crashes remain outside the server and
  app. No networking, microphone, clipboard, or UI ownership.
- **Python CLI:** explicit model installation, file transcription, start, status,
  and stop. It is a sibling client, not an automation interface into the Swift app.

`backend/` is one uv project generated from the owner's
[`python-service` template](https://github.com/mattjmcnaughton/templates) at a
pinned commit, with OpenTelemetry, database and Docker files omitted and a typer
CLI added. It has one package with `hagig` (CLI and internal server entry point)
and `hagig-worker` entry points. Do not split packages per process. The Swift app
lives in `clients/macos/`. Complete app build/terminal launch commands belong to
#23 once validated; do not invent them as working instructions now.

Keep portable backend code free of AppKit, Accessibility, and macOS permission
logic. This preserves a credible Linux path without a Linux desktop implementation.

### Inference network-isolation decision

Owner decision, revised 2026-10-28: two explicit modes, `required` and `disabled`.
Default to `required`; omission must not disable enforcement. Users may explicitly
select `disabled` as a supported product mode, not just a development exception.
There is no automatic mode or fallback. Reject unknown mode values rather than
loosening isolation. In required mode, unavailable or failed enforcement refuses
worker startup with an actionable, content-free error. In disabled mode, keep the
separate worker, private pipes, diagnostic containment, and environment/descriptor
hygiene, but do not claim OS-enforced network blocking. Neither mode permits
uploads, telemetry, automatic model downloads, or network-dependent inference.

The boundary remains the inference worker, not the entire app/server/CLI.
On macOS, required mode launches the worker as
`sandbox-exec -f seatbelt-v1.sb <bundled python> -I -m hagig.worker`, so the
policy applies before the interpreter, PyTorch or model files load. `sandbox-exec`
is deprecated; treat availability and behavior on supported macOS versions as a
validation gate, not a stable long-term platform guarantee. Disabling isolation is
an intentional configuration choice, never an implicit retry after setup fails.

Owner decision, 2026-11-10: Linux has no required-mode implementation initially.
Required mode refuses worker startup there with `isolation_unavailable`, the same
way any unsupported platform behaves; Linux users set `network_isolation =
"disabled"` explicitly. Disabled Linux relies on offline settings and process
separation only.

In both modes, the worker communicates through private pipes, not the server's
Unix socket. Launch it with an environment allowlist (offline and telemetry
settings below, no inherited proxies or credentials), `close_fds`, working
directory `/`, and stderr discarded. It writes a fixed ready acknowledgment before
importing the engine. Explicit model installation remains a separate operation
outside this boundary. A network sandbox alone does not restrict filesystem access
or prove absence of network attempts, diagnostic leakage, or other privacy violations.

Before adoption, exercise the real worker under the policy: successful inference,
missing/corrupt assets, worker restart, blocked outbound IPv4/IPv6 and DNS paths,
and an independent connectivity control outside the sandbox. Verify pipe IPC still
works and denied networking cannot escape through inherited resources. Record the
selected mode, policy, OS/tool versions, and observed denials separately from
source inspection. Disabled-mode success must not count as required-mode
enforcement evidence. Neither these documents nor workflow definitions establish
runtime enforcement.

## 2. Inference adoption gate

First candidate: Qwen3-ASR (`Qwen/Qwen3-ASR-0.6B-hf` or `Qwen/Qwen3-ASR-1.7B-hf`)
through Hugging Face transformers on PyTorch. Vocabulary biasing passes configured
terms through the model's documented free-form context prompt. This is an evaluation
target, not an adopted, benchmarked, or privacy-cleared dependency. mlx-whisper is
a comparison only. No other engine or plugin boundary is planned.

Hosted macOS evidence ([run 42636236736](https://github.com/mattjmcnaughton/hagig/actions/runs/42636236736),
Apple M1 virtual machine, CPU only, transformers 5.22.2, torch 2.15.0): both sizes
recovered 9 of 9 vocabulary terms with the prompt and 2–3 without, with no control
regressions. With a vocabulary prompt, both echo the prompt on digital silence,
an open risk for PRD AC9; the owner chose not to run a further silence check in
the spike (2026-11-10). PyTorch could not use the
virtual GPU, so these latencies are not representative. A physical-Mac run chooses
the size.

The adoption spike must establish:

1. A reproducible locked uv environment on Apple Silicon and Linux.
2. Actual Qwen3-ASR decoding with vocabulary biasing and paired non-vocabulary
   controls.
3. Accuracy, release-to-text latency, cold load time, resident/peak memory, and
   behavior up to the five-minute input cap, on MPS where available.
4. Loading from a relocated app bundle without checkout paths.
5. Source, runtime-network/write, and blocked-network evidence as separate records.

Model-file hardening:

- Track a manifest with the model repository, pinned revision, an allowlist of
  files and SHA-256 for **every** file (weights, `config.json`, tokenizer,
  processor and chat template), plus licenses and download sources.
- Load from local paths only with `use_safetensors=True`; never set
  `trust_remote_code`. Refuse repositories that offer only pickle formats.
- Set `HF_HUB_OFFLINE=1`, `TRANSFORMERS_OFFLINE=1`, `HF_HUB_DISABLE_TELEMETRY=1`
  and `DO_NOT_TRACK=1` before import; Seatbelt is the backstop if a library ignores them.
- Accept only official publishers. Safetensors prevents code execution on load,
  not a backdoored model.

Pin transformers, PyTorch and every transitive wheel in `uv.lock`. No dtype,
thread count, quantization or device policy is settled here. Do not claim MPS or
Neural Engine acceleration without observing the actual path.

## 3. Configuration and filesystem locations

Use TOML only for the alpha. Proposed schema (not implemented yet):

```toml
# $XDG_CONFIG_HOME/hagig/config.toml
# Default: ~/.config/hagig/config.toml, including on macOS.
[editor]
mode = "standard" # Default. Optional "vim" selects the bounded table in §8.

[model]
id = "qwen3-asr-0.6b" # Alias resolved by the pinned manifest; size not yet chosen.

[inference]
network_isolation = "required" # Default. "disabled" is an explicit opt-out; required on Linux.

[vocabulary]
terms = ["Hagig", "Ghostty", "Qwen", "Amp"]
```

The Python server parses configuration with stdlib `tomllib` and validates it
with pydantic; Swift receives only its needed settings through the API, not the
vocabulary. Reject unknown keys, unsupported model aliases, unknown editor modes,
and invalid types with field names and error codes, never raw offending values or
pydantic's default messages, which echo input. Configuration comes only from this
file, not environment variables. Read it at server startup. For the alpha, apply
edits by quitting the app, running `hagig stop`, and relaunching the app. No file
watcher or live reload command is needed; an active request's settings never
change. Invalid startup configuration returns an actionable error instead of
silently falling back to different settings.

`inference.network_isolation` selects the mode contract above. Apply it at
server/worker startup, not per request or from an untrusted client. Report the
selected mode in content-free status so explicit opt-out cannot be mistaken for
sandbox enforcement.

The settled editor choices are Standard by default and explicit Vim opt-in.
Reject unknown values; no global shortcut field or key-hook permission is needed
in this milestone. Native key routing and the bounded command table are in §8.

| Purpose | Proposed location/policy |
| --- | --- |
| Configuration | `$XDG_CONFIG_HOME/hagig/config.toml`, default `~/.config/hagig/config.toml` |
| Models | `$XDG_DATA_HOME/hagig/models/<manifest-id>/`, default `~/.local/share/hagig/models/<manifest-id>/` |
| Runtime socket/lock | Private per-user runtime directory; see below |
| Recordings/transcripts | In memory only; no history directory or temporary audio files |
| Logs | Content-free stderr by default; no persistent app log file by default |

Prefer a valid, owner-only `$XDG_RUNTIME_DIR/hagig/`. On macOS without it, use the
OS-provided per-user temporary directory and a `hagig/` child. On Linux without it,
use an owner-validated `/tmp/hagig-<uid>/` directory. Require owner-only directory
permissions (0700), socket permissions (0600), no symlink substitution, and the
expected owner. Fail closed on an unsafe preexisting path rather than chmod or
delete another owner's object. Check Unix-socket path length before binding.

The private-alpha threat boundary is other OS users and accidental exposure, not
a malicious process already running as the same user. File permissions are not
authentication against that process. Do not listen on TCP.

## 4. Installation and model acquisition

Proposed command: `hagig model install <manifest-id>`. It is the explicit network
action, run in the CLI process; starting the app, server or worker never downloads
or repairs a model. Download only the manifest's allowlisted files at the pinned
revision into a model-only staging directory, verify every SHA-256, then atomically
publish the validated installation. A failed install must not replace a valid one.

Normal loading resolves only installed manifest entries, validates the expected
files, and returns `model_missing` or `model_invalid` without attempting recovery
networking. A versioned installation must not change beneath a warm worker.

Local-first plan (#23), not an implemented build/install recipe: build from a
clone and launch the resulting relocatable `.app` from a terminal. The eventual
verified instructions must name prerequisites, exact build command, artifact,
terminal launch command, explicit model install and stop/relaunch procedure.
No `/Applications` placement, Homebrew or public release is required. #24 owns
later distribution; it is not a prerequisite for this source-build workflow.

The build runs `uv sync --frozen --no-dev`, the explicit build-time network step,
then copies the uv-managed interpreter (python-build-standalone) and the locked
environment into the bundle beside the app. Sign every bundled `.so` and `.dylib`.
At runtime the app and CLI exec the bundled interpreter directly with
`UV_OFFLINE=1` and `UV_PYTHON_DOWNLOADS=never`; launch never resolves, syncs or
downloads anything. Resolve helper paths relative to the installed bundle, not
ambient PATH or the developer checkout. Model files remain separate to keep
downloads explicit. No login service or automatic updates for the alpha.

The packaging spike must test relocation (uv environments are not relocatable by
default), architecture compatibility, native loader paths, required local signing,
permission stability across rebuilds, and installation without developer
runtimes. Public notarization remains deferred.

## 5. Server startup and lifecycle

On app launch or a CLI operation needing the server, try the private socket. If
absent, spawn the bundled server and wait until `GET /v1/status` answers, with a
bounded deadline. Use an OS advisory lock (`fcntl.flock` on a persistent 0600
`server.lock`, never unlinked) held for the server's lifetime to arbitrate
simultaneous startup. Only the lock holder may remove an owner-validated stale
socket. The server binds the validated socket itself, 0600 from creation, and
hands it to uvicorn. A second startup must attach to the winner, not launch
another worker. Never kill a PID just because it appears in a stale file.

Proposed startup/connect deadline: 5 seconds. This covers server readiness, not
model loading. Return a clear startup error on timeout; no unbounded spawn loop.
API version mismatch returns an explicit incompatibility error instead of
restarting or killing an active server from another installation.

The server is per-user and on demand. It remains alive after clients exit. The
worker loads on first transcription, stays warm with its validated configuration,
and has no idle eviction in the alpha. This intentionally retains model memory;
`hagig stop` is the release mechanism. Logout/OS process termination ends the
session; the server needs no login registration or durable recovery state.

`hagig stop` does not start a missing server. It stops admission, invalidates active
work, requests worker exit, escalates if necessary, cleans up its owned runtime
socket, and exits. Closing a non-owning client must not cancel another client's work.

## 6. Client API and request ownership

HTTP/1.1 over the private Unix socket; no TCP listener. All paths are under `/v1`.
The app uses swift-server AsyncHTTPClient with `http+unix://` URLs; the CLI uses
httpx with a Unix-socket transport. JSON bodies are at most 64 KiB and carry
`Content-Length`; audio uploads may instead be chunked (below). No WebSockets.
FastAPI's documentation and OpenAPI routes and
uvicorn access logs are disabled. Errors are `{"code": "<stable code>"}` with no
free-form message, raw input or native diagnostics.

| Method and path | Contract |
| --- | --- |
| `GET /v1/status` | `api_version`, `state` (`idle` or `busy`), `worker`, `network_isolation`, `config_generation`, app settings (`editor_mode`, `model_id`, `language`), audio format, limits and deadlines. No content or vocabulary. Never starts a server |
| `POST /v1/requests` | Reserve the single active slot before app recording or CLI decoding → `201 {request_id, config_generation, model_id}`, or `409 {"code":"busy"}`. No queue or preemption |
| `PUT /v1/requests/{id}/audio` | Raw canonical audio (`application/octet-stream`). The app streams it with `Transfer-Encoding: chunked` from recording start; the CLI may send one `Content-Length` body. The end of the body starts inference → `200 {"text": ...}` or an error. At most one upload per request. This connection owns the request: losing it before the response cancels |
| `DELETE /v1/requests/{id}` | Cancel → `204`, also for terminal, expired or unknown IDs. Not proof the request existed |
| `POST /v1/stop` | Invalidate work, stop admission → `202`, then reap the worker, remove the socket and exit |

Request IDs are server-generated, random and opaque. The client must open the
upload within 5 seconds of `201`; otherwise the server releases the slot and a
late upload fails `404 request_not_found`. The app opens it immediately after
admission, before the microphone starts and including any permission prompt, and
writes chunks as capture produces them. From then on the upload connection owns
the request, so closing it, including the kernel closing a crashed app's socket,
cancels at once (PRD P5). `DELETE` remains an explicit cancel from any connection.

Reservation lasts at most 330 seconds from `201` until the body ends, enforced by
the server because uvicorn has no body-read timeout. Inference then has a separate
120-second hard deadline, including worker launch and model load. Clients wait up
to 125 seconds for the response after the body ends. These are failure bounds,
not acceptable interactive latency. The handler waits for the worker result and
for client disconnect together, and a disconnect cancels the worker; Starlette
does not interrupt a handler on disconnect by itself.

Audio is canonical mono 16 kHz float32 little-endian PCM: nonempty, 4-byte
aligned, every sample finite and in [-1, 1], at most 19,200,000 bytes (300
seconds). Chunk boundaries are arbitrary: the server validates samples as they
arrive, carries an incomplete trailing sample into the next chunk, counts bytes
against the cap (and rejects an oversized `Content-Length` before reading), and
fails a misaligned or empty body at its end. Swift converts microphone audio;
the CLI decodes supported WAV input into the same format. Do not pass filesystem
paths, vocabulary, model paths or configuration overrides to the server. Reserve
before capture to avoid five minutes of recording followed by busy rejection.
Swift keeps no full recording buffer. The server holds the audio in memory, since
the engine does not stream, then forwards it over private worker pipes using
bounded framing. Peak memory includes multiple buffers and the model, and must
be measured.

The result's serialized response must fit 64 KiB; otherwise fail with
`result_too_large` and never truncate. Preserve Unicode and newlines; normalize
whitespace-only recognition to `""`, which is successful no-speech and authorizes
no review, Copy or stdout. Proposed codes and statuses: `invalid_request` 400,
`invalid_audio` 400 or 413, `request_not_found` 404, `busy` 409, `cancelled` 409,
`model_missing`/`model_invalid`/`isolation_unavailable`/`server_stopping` 503,
`worker_failed`/`result_too_large` 500, `deadline_exceeded` 504,
`incompatible_api` client-local. Unknown codes are generic failures, never success.
Model errors never trigger acquisition. Contract fixtures (request and response
bytes, expected client outcomes) are shared by pytest and Swift tests; they prove
codec and state expectations only.

## 7. State machine and cancellation

Server request lifecycle:

```text
Idle -> Reserved -> Receiving audio -> Loading worker -> Transcribing -> Result returned -> Idle
                    any active state -> Cancelled/Expired/Failed -> Idle
```

Only one admitted request exists, including its recording. An invalid or
busy request must not disturb it. Each terminal transition releases buffers and
the active slot exactly once. Cancellation is `DELETE`, loss of the upload
connection, a missed upload-start or reservation deadline, or stop. Worker replies carry a server-assigned
generation as well as the request ID; a stale worker reply cannot match a new
request.

Swift additionally owns local states: ready, awaiting admission, recording,
uploading/transcribing, review/editing, copy initiated, and cancelled.
The server cannot enforce final UI delivery; **both sides must invalidate work**.

- On Escape/Cancel during capture or transcription, first invalidate the local
  generation and discard pending display/delivery work, then close the upload
  connection. Do not wait for an acknowledgment before preventing delivery.
- Serialize cancel, result handling, editor changes and Copy initiation through
  the app's main-actor state. Recheck the live generation immediately before any
  display or clipboard write. Vim review Escape is mode switching, not Cancel.
- Stop/cancellation before admission completes must not later start
  microphone capture. Cancel a subsequently granted reservation.
- Server cancellation invalidates the request before stopping native computation.
  If inference cannot be interrupted safely, terminate the worker; never call
  native inference concurrently with teardown inside the same process.
- Proposed escalation: request exit, wait up to 1 second, terminate, then kill after
  another 1 second if needed. Reap the child before admitting work to its successor.
- A worker crash fails that request. Do not retry the recording automatically;
  restart lazily for the next user request and avoid an automatic crash loop.

Cancellation that wins before display/Copy initiation prevents that effect. Cancellation
after a clipboard write cannot undo that effect or the user's later paste; communicate
the boundary accurately. Tests must exercise both orderings rather than promise
an impossible rollback.

The review transcript, Vim register and undo state are app-owned memory after
server completion. Dismiss, a new recording or app exit discards them; do not
accumulate a transcript list or serialize editor state.

## 8. macOS capture, editable review and Copy

Use native microphone capture and sample-rate conversion. Check permissions before
recording, handle device loss/interruption explicitly, and never persist captured
audio. An interruption cancels capture rather than delivering an unexplained
partial prompt. The five-minute cap intentionally produces a partial recording;
it is a separate, documented completion path. Warn at 4:45; Stop and 5:00 cap
firing must converge on one completion. Cancel discards rather than transcribes.
Record/Stop are menu-bar controls; there is no global shortcut or key injection.

Every live nonempty result enters editable review. Standard native editing is the
default. Optional Vim mode is selected by the TOML schema in §3. This table is the
bounded agreed command set, not a promise of full Vim compatibility:

| Area | Supported keys / behavior |
| --- | --- |
| Modes | Vim starts in Normal with a visible mode label; Normal, Insert, character Visual and line Visual; `i`/`a` enter Insert before/after cursor, Escape returns to Normal, `v`/`V` enter character/line Visual |
| Motions | `h`/`j`/`k`/`l`, `w`/`b`/`e`, `0`/`$`, `gg`/`G`, counts for supported motions/commands |
| Changes | `x`, `dd`, `dw`, `cw`; `cw` enters Insert |
| Register | `yy`, `p`; Vim deletes/yanks/paste use an in-memory register, never the macOS clipboard |
| History | `u`, `Ctrl-R`; in-memory undo/redo, cleared with the transcript |
| Native editing | Cmd-A selects all; Cmd-C copies selected text; Copy all / Cmd-Shift-C copies the entire edited buffer. Native paste and undo remain available; every system clipboard cut/copy route uses the currentHostOnly writer |
| Enter | Inserts a newline only in Standard editing or Vim Insert mode; never submits |
| Excluded | Ex commands, plugins, macros, dot-repeat, external editor integration and broader Vim emulation |

Fixtures must exercise the entire table in multiline and empty text, word/line
boundaries, counts, mode transitions, Visual selections, undo/redo and register
lifetime; unsupported commands must not invoke an external editor or write the
clipboard. Escape in review is an editor-mode action; Dismiss is explicit and
keyboard-accessible. Standard editing and native Command routes must remain usable
with Vim enabled. #22 implements/tests these details, not this document.

One app-owned clipboard adapter must mediate the Copy button, keyboard equivalents,
menu/context-menu Copy and Cut, and native Command-C/Command-X in either editor
mode. Use `NSPasteboard` current-device-only writes (`currentHostOnly`); do not let
a default text-view responder bypass that policy. Explicit Copy all / Cmd-Shift-C
copies the entire current edited buffer; Cmd-C and native selection Copy/Cut act
on the selected text. Empty text must not clobber the clipboard.
Vim's register operations never use that adapter. Native paste reads the clipboard
into review only; it never targets another application. No clipboard change on
result display, edits, internal Vim operations or Dismiss. Copy feedback reflects
write success and is invalidated by edits; failure retains text for retry.

Do not restore or clear the user's clipboard. Current-device-only writes do not
control local clipboard managers or destination retention/transmission. Require
the second-device check with an ordinary-copy positive control in PRD AC5.

No Accessibility destination inspection, app/window/input identity snapshot,
focus restoration, simulated paste, or automatic submission is in this milestone.
The constitution's stricter rules still govern any future automatic delivery;
AC1/AC2 destination work is deferred, not a blocking feasibility spike for Copy.
Review can take editor focus intentionally. Routine feedback must not activate a
destination. Respect reduced motion, native accessibility names and model display.

## 9. CLI contract

Planned alpha command surface (typer); none of it is implemented yet:

```text
hagig start
hagig transcribe <audio.wav>
hagig model install <manifest-id>
hagig status
hagig stop
```

`start` starts or attaches to the server and exits after readiness, without
loading a model or downloading. `status` and `stop` never start an absent server.
There are no public fake-worker commands; the test fake is test-only.

Accept PCM WAV at 16-bit integer or 32-bit float, mono/stereo, 16/44.1/48 kHz,
maximum five minutes. Decode with a bounded parser using `struct` and numpy
(stdlib `wave` cannot read float32), average stereo, and resample with
deterministic linear interpolation. Reject unsupported or malformed formats
without attempting downloads.

`transcribe` starts/connects to the server, reserves a request, decodes and uploads
canonical audio, prints only the final text plus newline on stdout, and sends
safe diagnostics to stderr. Ctrl-C invalidates the client's request and cancels
it. No microphone, clipboard, or paste operations. Never change the input file.

Proposed exit codes: 0 success, 1 transcription/server failure, 2 usage/configuration
error, 3 busy, 130 interruption. An empty recognized result is success with empty
stdout. `status` reports stopped without starting a server; `stop` on a stopped
server succeeds. Model installation is separate from transcription-server startup.

## 10. Privacy, errors, and diagnostics

Never log transcript, audio, vocabulary terms, raw config, request bodies, or
full worker messages. Use stable codes, stage names, durations, versions, and
bounded numeric counters. Do not echo a filename or native error string that may
contain sensitive input without deliberate sanitization. Worker stdout is
protocol-only and stderr is discarded; set transformers logging to errors only
and confirm no library prints prompts, tokens or vocabulary before adoption.

Ordinary errors must be actionable without leaking content: permission needed,
model missing/invalid, busy, no speech, worker failed, or deadline exceeded. A result
is not success if decoding failed. No crash dump or diagnostic export is enabled
by default. OS swap/crash services and third-party clipboard/destination retention
are separate boundaries; finite application tests cannot promise secure erasure
or control of all OS-managed storage.

Dependency review must cover native wheels, model loaders, tokenizers, processors,
chat templates, transitive dependencies, build hooks, and every automatic download
or telemetry path, including Hugging Face Hub and tokenizer download fallbacks.
Explicit installer traffic is distinct from forbidden runtime traffic. Observe
actual network attempts and local writes, not just successful connections. Test
missing/corrupt models with networking both available and blocked.

### Tool and dependency approval inventory

Repository guidance owns approval policy; this inventory records its application
to the milestone, not an additional grant:

| Surface | Approval / constraint |
| --- | --- |
| Python runtime | uv-managed CPython (python-build-standalone), pinned in the project; `uv.lock` committed |
| Server/CLI starting set | fastapi, uvicorn, pydantic, typer, httpx, numpy; stdlib `tomllib`; structlog from the template, configured for content-free fields only. No OpenTelemetry or pydantic-settings |
| Inference | transformers and PyTorch with their locked transitives (huggingface_hub, tokenizers, safetensors) for Qwen3-ASR, subject to the §2 adoption gate; no new engine/plugin framework |
| Swift client | swift-server AsyncHTTPClient for HTTP over the Unix socket; review its SwiftNIO transitives, including vendored BoringSSL, before adoption |
| Native editor/UI | Existing Swift/AppKit/SwiftUI and shared render harness; no external editor, Vim dependency or new tool |
| Build/test | uv, ruff, ty, pytest and just; copier for generating `backend/` from the template; existing Swift/Xcode commands; GitHub-hosted native CI; ask before any manual workflow dispatch |
| Network observation | Distro-packaged strace approved for Linux observation only, not an app dependency; other new development tools need specific approval |
| Not selected | Anything else, including audio/resampling libraries, needs owner approval first |
| Packaging | Local ad-hoc signing as needed; public certificates/notarization, releases and Homebrew-tap writes deferred and not granted |

## 11. Verification strategy

Map implementation tickets to the PRD's AC identifiers. Keep enduring tests at
public interfaces: API operations, CLI outcomes, and app-visible delivery
effects. Use temporary probes freely for spike evidence; do not retain tests of
private call order or decorative formatting.

| Layer | Evidence |
| --- | --- |
| Portable Python (pytest unit/integration/e2e) | Request limits, busy admission, upload-start and reservation deadlines, chunk-boundary validation, startup contention, configuration validation, malformed audio, upload disconnect, cancellation/late results, worker crash/deadline recovery, CLI stdout/errors/input preservation, Linux required-mode refusal |
| Inference integration | Actual pinned model; paired biased/unbiased fixtures and controls, supported WAV variants, long audio, cold/warm latency and memory; silence and noise outcomes for AC9, including the known prompt echo |
| macOS isolation | Real worker under `seatbelt-v1.sb`: outbound IPv4/IPv6/DNS denied while pipe IPC and inference work, with an unsandboxed connectivity control |
| macOS build | Swift target and the bundled interpreter/environment, signing and loading on macOS; Linux success is not a macOS build |
| Physical Mac | Record/Stop, permissions, microphone/device loss, native editor/keyboard routing, cancel/Copy races, second-device clipboard control, relocated local app and human usefulness; owner final tests deferred |
| Privacy | Distinct source inspection, observed network/write behavior, blocked-network operation; include failure and recovery paths |

Automated fake-worker tests should intentionally return results after cancellation,
reuse stale generations, crash while active, and stall. At least one real-worker
test must establish recovery after process death. Verify service/process cleanup,
not just returned text. An additional Apple device is needed for the observational
Universal Clipboard check; API inspection alone is not that evidence.

The prototype's browser checks establish only the HTML artifact's behavior.
GitHub-hosted macOS build, shared-view rendering and feasible automated native
interaction checks are the development path. Prove/inspect the Ready artifact
path before representative state collection; the synthetic shell has historical
render evidence, not real capture/editing evidence. Hosted checks do not replace
physical-Mac, second-device or human-corpus acceptance. Use synthetic non-sensitive
public fixtures only; do not assume acceleration availability in a VM. PRD §5
owns the AC-to-ticket/environment evidence matrix; do not duplicate it here.

## 12. Implementation sequence

| Risk investigation | Question, evidence, and exit decision | Unblocks |
| --- | --- | --- |
| Inference (S2 spike, `spike/inference-s2` branch) | Hosted macOS runs are done (§2). Remaining: a physical-Mac run of both Qwen3-ASR sizes for MPS latency and memory, which picks the size. | Model manifest, worker |
| Native copy-only path (#21/#22) | Validate Record/Stop/cap/Cancel, editable Standard/Vim review, all currentHostOnly cut/copy routes and keyboard/accessibility behavior. No destination-identity or automatic-paste work in this milestone. | Usable capture/review/Copy, final platform acceptance |
| Packaging and privacy (#10/#23) | Can the bundled interpreter, environment and model run from a relocatable bundle without forbidden runtime behavior? Produce loader/install evidence plus separate source/network/write/blocked-network findings. Proceed, patch dependencies, or reject adoption. | Distribution layout, alpha installation |

Stop early on a privacy violation rather than spending effort on speed measurements.

Then implement vertical slices:

1. **Python backend:** generate `backend/` from the template; real CLI → REST
   server → isolated worker, explicit model install, WAV input, one active request,
   errors and cancellation, macOS Seatbelt enforcement. The Swift client switches to
   the REST API in the same change. AC8–AC13 as applicable.
2. **Record to review:** #21 Swift capture → same server → #22 editable in-memory
   transcript, explicit Copy/Dismiss, cap and permissions. AC3–AC5, AC9, AC14.
3. **Local bundle:** #23 can begin bundle feasibility early; its built artifact
   against integrated capture/editor/backend feeds final #10 acceptance. Do not
   make their issue closure dependencies circular.
4. **Daily-use alpha:** #10 held-out human measurements and mandatory privacy/
   failure evidence; owner physical Mac/second-device tests remain deferred, not
   satisfied by CI. #24 public distribution follows separately.

Each ticket should name a user-visible or risk-retirement outcome, relevant
ACs/constitutional boundaries, dependencies, bounded scope, verification environment,
and required evidence. Do not organize tickets as isolated Swift/server/CLI silos.
Create external tracker issues only when requested.

## 13. Decisions to review, and evidence still missing

Settled owner choices: Standard default, optional bounded Vim, menu-bar Record/
Stop without a global shortcut, 5:00 cap/4:45 warning, local bundle before separate
distribution, required-default/explicit-disabled isolation, functionality-first
numeric measurements, and (2026-11-10) a Python backend managed with uv and
generated from the owner's template, REST over the private Unix socket with no
TCP, Swift AsyncHTTPClient, no Linux required-mode implementation initially,
and Qwen3-ASR through transformers as the first candidate. Do not
reopen these as unanswered gates. Streamed uploads owning the request (§6),
WAV formats, restart-to-apply configuration, remaining resource caps and hard
deadlines retain their proposed status until implementation evidence validates
them; changes must not silently
alter safety/privacy commitments.

No review can substitute for these still-unverified facts:

- Qwen3-ASR size, MPS latency, memory and long-input behavior on a physical Mac.
- Silence/noise behavior for AC9: the biased model echoes its prompt on silence.
- Seatbelt enforcement for the Python worker, and Hugging Face/transformers
  offline behavior under it.
- A relocatable, signed bundle of the uv-managed interpreter and environment.
- The AsyncHTTPClient and Python dependency privacy reviews.
- Native capture/editor/clipboard routing and cancellation boundary behavior.
- Validated local app build/terminal launch recipe, hosted exact-head evidence,
  and owner final physical-Mac/human/second-device tests and consented fixtures.

If evidence contradicts an agreed product or constitutional requirement, document
the conflict and obtain an explicit decision; do not relabel an unsafe
implementation as satisfying the requirement. Missed numeric performance/usefulness
targets must be reported as measurements, not misrepresented as either passing
results or unagreed first-working-app blockers.
