# Copy-only client protocol v1

Contract revision: 2026-11-08, issue #9, coordinated with #21. This is the
authoritative **implementation target**, not evidence of real inference. The
merged controlled service only implements its earlier fake subset. Normal app
operation must reject `worker: "controlled_fake"`; fixture peers are test-only.
Changes to this contract require explicit #9/#21 coordination before coding.

## Transport, startup and identity

Unix-domain stream only. Each frame is `kind:u8 | length:u32 big-endian | payload`.
Kind 1 is UTF-8 JSON object, at most 65,536 payload bytes. Kind 2 is audio, at most
262,144 bytes. Validate header before allocation; read/write fully across partial
operations; reject unknown kinds, invalid UTF-8/JSON, duplicate JSON keys and
unknown client fields. Client response decoders may ignore unknown response fields
for additive metadata; version/type and required fields must still validate.
No compression, audio file paths, vocabulary, configuration overrides or model
paths cross the client wire. All JSON numbers below are integers except PCM.

All controls require `version: 1` and `type`. Request operations also require
`request_id`: 1–128 ASCII bytes from `[A-Za-z0-9_-]`. IDs are connection-local,
opaque, case-sensitive. Use a fresh ID for each request on a connection; reconnect
before reusing an ID. Worker generation is separate and server-private. A
client must match both its local generation/connection and the returned ID.

Planned real commands, implemented by #9, **not available on the merged fake baseline**:

```
hagig start
hagig transcribe <audio.wav>
hagig model install parakeet-tdt-0.6b-v2-int8-v1
hagig status
hagig stop
```

The app resolves its bundled `hagig` helper by absolute bundle-relative location,
never PATH. `start` starts/attaches and exits after socket readiness/hello, without
loading a model or downloading. Configuration is read only by the winning server
at startup from `$XDG_CONFIG_HOME/hagig/config.toml` (default
`~/.config/hagig/config.toml`). Default isolation is `required`; `disabled` requires
explicit validated TOML. A connecting client never changes a live server's mode.
Invalid config is a startup failure, not fallback. To apply edits: quit app,
`hagig stop`, relaunch. `status`/`stop` never start an absent server.

Socket: `$XDG_RUNTIME_DIR/hagig/server.sock` when that absolute directory is valid,
owner-only 0700 and owned by the user. Otherwise, only when XDG_RUNTIME_DIR is
unset: macOS `$TMPDIR/hagig/server.sock` (the same absolute per-user TMPDIR
inherited by app and helper, owner-only 0700, no symlink; do not substitute a
different Foundation-normalized temporary root); Linux
`/tmp/hagig-<uid>/hagig/server.sock`. An invalid supplied XDG directory fails
closed, not fallback. The `hagig` child directory is 0700, socket and persistent
`server.lock` are 0600, owner-validated without symlinks. Maximum full socket path
is 100 encoded bytes. Only the lifetime-lock holder may remove a validated stale
socket. Never kill a PID read from a file. Startup races attach to the winner.

Startup/connect/hello/control write and partial-frame assembly each have an
absolute 5-second I/O budget, never reset for each byte. Non-inference exchanges
(hello, begin, cancel, status, stop) have a single 5-second budget from sending
the control through receiving the complete response, including first-byte wait.
On timeout, invalidate local work and disconnect; do not wait indefinitely for
accepted/cancelled or retry an unknown-outcome request. `start` has a 5-second
readiness budget after spawn; clients must also bound helper execution. A
version mismatch reports `incompatible_protocol` and closes that connection;
do not kill/restart an incompatible active service automatically.

## Handshake and settings

Client first sends `{"version":1,"type":"hello"}`. Exact required real response:

```json
{
  "version": 1,
  "type": "hello_ok",
  "worker": "inference",
  "network_isolation": "required",
  "config_generation": "server-1",
  "settings": {
    "editor_mode": "standard",
    "model_id": "parakeet-tdt-0.6b-v2-int8-v1",
    "model_revision": "1ab9323565ddb038682214b292f588070a538ce2",
    "language": "en"
  },
  "audio": {"encoding":"f32le","sample_rate_hz":16000,"channels":1},
  "limits": {
    "control_bytes":65536,
    "audio_chunk_bytes":262144,
    "audio_total_bytes":19200000,
    "recording_seconds":300,
    "warning_seconds":285,
    "request_id_bytes":128
  },
  "deadlines": {"control_seconds":5,"reservation_seconds":330,"computation_seconds":120}
}
```

`editor_mode` is `standard` or `vim`; `network_isolation` is `required` or
`disabled`. `config_generation` is an opaque server-lifetime token with the same
syntax/cap as request IDs; example `server-1` is synthetic, not a fixed value.
It identifies the frozen configuration, not a hash of sensitive vocabulary.
`model_id` identifies the immutable manifest (including tokenizer and hashes);
`model_revision` identifies its ONNX export. Tokenizer source remains pinned to
NVIDIA revision `ae9ad07059c7c739ffaf932226a8fe64ae2620b0` in that manifest,
not an untrusted client choice. Vocabulary and paths are never returned.
Hello does not certify installed model validity, native adoption or enforcement.
Model missing/invalid is a request error; the server may start without assets.

Clients require the listed format/caps/deadlines and known setting enum values;
incompatible required capabilities fail explicitly rather than guessing. Real
service must never advertise `inference` while selecting a fake worker. No
streaming results, feature negotiation framework or per-request model changes.

## Admission, audio and terminal outcomes

After hello, client sends `{"version":1,"type":"begin","request_id":"r1"}`.
The service immediately reserves its single slot (including recording/upload),
or sends `error` with code `busy`. No queue/preemption. The acceptance response:

```json
{"version":1,"type":"accepted","request_id":"r1","config_generation":"server-1","model_id":"parakeet-tdt-0.6b-v2-int8-v1"}
```

The two identities must equal hello. App starts capture only after matching
accepted and rechecking its live main-actor generation. Cancellation while
awaiting admission invalidates locally; cancel any subsequently accepted slot.
Failed validation releases only the caller's reservation, never another owner's.

Send nonempty kind-2 chunks of aligned canonical mono 16 kHz float32 little-endian
PCM. Every sample must be finite and in [-1,1]. Total <=19,200,000 bytes (4,800,000
samples / 300 seconds). Kind-2 has no ID: it belongs to this connection's one
admitted request. Audio before acceptance, after end_audio, misaligned, zero-size,
nonfinite/out-of-range or over-cap audio is malformed: close connection and
invalidate only its work. No native WAV reader handles client input.

After upload send `{"version":1,"type":"end_audio","request_id":"r1"}`.
No audio frames means `error: invalid_audio`, not a synthetic transcript. A
nonempty supported silent input may produce the empty result below; this requires
real silence evidence and does not claim the candidate's known failure is fixed.
Reservation lasts 330 seconds from accepted through end_audio; then a separate
120-second absolute computation budget includes worker launch/model load. Clients
wait up to 125 seconds for the first terminal-frame byte after end_audio (server
computation plus scheduling/I/O allowance). **Never use the 5-second control timeout as a transcript
timeout.** Once a result frame starts arriving, its assembly still has 5 seconds.
Idle post-hello connections may close after 330 seconds; no heartbeat required.

```json
{"version":1,"type":"result","request_id":"r1","text":"Synthetic fixture only.\nSecond line: λ."}
```

One live result or request error is terminal. Result `text` is always a string;
the entire serialized JSON payload must fit 65,536 bytes (including escaping,
ID and envelope), otherwise `result_too_large`; never truncate. Unicode and
newlines are preserved. Whitespace-only recognition is normalized to `text:""`.
Empty result is successful no-speech: no review, copy, paste or stdout newline.
Nonempty CLI result prints text plus one newline only; errors print stable safe
codes to stderr. Exit 0 success (including empty), 1 service/transcription error,
2 usage/configuration/unsupported input, 3 busy, 130 interruption. Input unchanged.

```json
{"version":1,"type":"error","request_id":"r1","code":"model_missing"}
```

Request errors always carry the matching string ID. Connection-level errors carry
`request_id:null`. No free-form message/native diagnostics or retry-after field:
clients map stable code to safe local text. Codes: `busy`, `model_missing`,
`model_invalid`, `invalid_audio`, `worker_failed`, `deadline_exceeded`,
`result_too_large`, `incompatible_protocol`, `invalid_request`, `server_stopping`.
Unknown error codes are generic failure, never success. Startup/CLI-local codes
(`configuration_invalid`, `unsafe_runtime`, `runtime_unavailable`,
`runtime_path_too_long`, `startup_failed`, `connection_timeout`) are not promised
wire frames before connection. Malformed input may close without an error frame.
Model errors never trigger acquisition. Real worker failure has no automatic
request retry; lazy fresh worker on a subsequent request only, after reap.

## Cancellation, disconnect, status and stop

`{"version":1,"type":"cancel","request_id":"r1"}` returns
`{"version":1,"type":"cancelled","request_id":"r1"}` even if already terminal
or not owned by that connection. It cannot cancel another client's request.
This ack is not proof of another request's existence or synchronous child reap.
The server invalidates before stopping/reaping the child; admission may remain
busy until cleanup completes. A successful worker stays warm until explicit stop;
no idle eviction. A cancelled active worker must retire before reuse.

Owner disconnect invalidates owned reservation/inference. Closing a nonowner or
successful connection does not stop the service/warm worker. Unsent serialized
success is discarded if cancel/stop wins before delivery starts. Bytes already
sent cannot be retracted. Client locally invalidates immediately and drops late
results, including a result arriving before the cancellation acknowledgment.
Cancelled IDs are never reused on that connection. Neither side delivers content
after its cancellation wins. Cancelled ack is not a result/error terminal event.

After hello, `{"version":1,"type":"status"}` responds:

```json
{"version":1,"type":"status","state":"idle","worker":"inference","network_isolation":"required","config_generation":"server-1","model_id":"parakeet-tdt-0.6b-v2-int8-v1","server_pid":123,"worker_pid":null}
```

`state` is `idle` or `busy` (reservation, loading and inference all busy).
`worker_pid` is null or a positive integer for the owned active/warm child, not
worker self-report. No result, audio, vocabulary or paths. PID fields are
diagnostic, never authority to kill. Status does not acquire/check/repair models.

`{"version":1,"type":"stop"}` invalidates work, stops admission and responds
`{"version":1,"type":"stopped","request_id":null,"code":null}` before closing.
The stopped frame acknowledges shutdown initiation, not completed process cleanup.
CLI `stop` waits for lifetime lock release and socket removal (6-second cleanup
observation budget); the app should use that helper if it needs completed stop.
If cleanup fails the service must retain ownership and block successors. No
automatic mode fallback, and no kill-by-PID cleanup.

## Fixtures and conformance boundary

[`protocol-v1-fixtures.json`](tests/fixtures/protocol-v1-fixtures.json) supplies
synthetic literal bytes plus expected client outcomes. Fixtures prove codec and
state expectations only; they cannot prove real speech, isolation or native
capture. Test peers must be explicitly test-only, never a runtime fallback.
The controlled service's fake fields and private enveloped one-byte action/result
protocol are not accepted by the real protocol. #9 owns the separate bounded private
worker protocol and native loading; #21 must not depend on private pipe bytes.
