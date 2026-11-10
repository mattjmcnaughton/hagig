# Hagig REST API v1 and worker pipe protocol

Contract revision: 2026-11-10 (#44). This is the implementation target for the
Python server and CLI (#45) and the Swift client (#46). It is not implemented
yet and is not evidence of transcription, isolation or native behavior. It
details [TDD §5–§7](../docs/technical/tdds/01-mvp.md); if this file and the TDD
disagree, the TDD wins and this file is the bug. Change the contract only with
the owner's agreement, and update the
[shared fixtures](tests/fixtures/rest-v1-fixtures.json) in the same change.

## Transport

- HTTP/1.1 over the server's private Unix socket only (owner-only 0700
  directory, 0600 socket; location and startup locking in TDD §3 and §5). No TCP
  listener, no WebSockets, no HTTP/2, no TLS.
- The app uses AsyncHTTPClient with `http+unix://` URLs; the CLI uses httpx with
  a Unix-socket transport. Clients send a `Host` header, as HTTP/1.1 requires;
  the server ignores its value. Clients do not send `Expect: 100-continue`.
- FastAPI's docs and OpenAPI routes and uvicorn's access log are disabled.
- All paths are under `/v1`, exactly as listed below. Any other path (including
  a trailing slash), or a method a path does not support, returns
  `400 {"code":"invalid_request"}`, never a redirect or `405`.

## JSON and errors

- Every JSON body is a UTF-8 JSON object of at most 65,536 bytes, sent with
  `Content-Length` and `Content-Type: application/json`. JSON responses are never
  chunked. v1 has no JSON request bodies.
- The server encodes JSON compactly without escaping non-ASCII, as
  `json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(",", ":"))`
  does. That encoding defines every byte size below, and the fixtures' bytes.
- Every error response is exactly `{"code": "<stable code>"}`. No response
  carries a message, raw input, path, vocabulary or native diagnostic.
- Clients ignore unknown fields at any depth of a response object, so later
  additive metadata is not a break. A missing required field, a wrong type or an
  unknown enum value is not ignored (see Client rules).
- Malformed HTTP framing can be rejected by uvicorn before the application runs,
  with a non-JSON body or a closed connection. Clients treat that as a generic
  failure.

### Stable error codes

| Code | HTTP status | Meaning |
| --- | --- | --- |
| `invalid_request` | 400 | Unknown route or method, a body on an endpoint that takes none, or a wrong upload `Content-Type` |
| `invalid_audio` | 400 | Empty, misaligned, non-finite or out-of-range audio |
| `invalid_audio` | 413 | Audio over 19,200,000 bytes, declared by `Content-Length` or counted while streaming |
| `request_not_found` | 404 | The ID has no reservation waiting for its upload: unknown, terminal, expired, or already uploading |
| `busy` | 409 | Another request holds the single active slot |
| `cancelled` | 409 | `DELETE` cancelled this request while its upload connection was still open |
| `model_missing` | 503 | The configured model is not installed |
| `model_invalid` | 503 | The installed model fails validation |
| `isolation_unavailable` | 503 | Required network isolation cannot be established on this host |
| `server_stopping` | 503 | `POST /v1/stop` was accepted |
| `worker_failed` | 500 | The worker crashed, exited, broke the pipe protocol or reported an engine failure |
| `result_too_large` | 500 | The result does not fit the 64 KiB limit; it is never truncated |
| `deadline_exceeded` | 504 | The reservation or computation deadline passed |

Client-local codes, never sent by the server:

- `incompatible_api`: the server does not speak this API version (see Client
  rules).
- `deadline_exceeded`: the client's own 125-second wait ran out. It uses the
  same code and message as the server's 504.

Model errors never trigger a download or repair. `hagig model install` is the
only network step.

## Endpoints

| Method and path | Success | Errors |
| --- | --- | --- |
| `GET /v1/status` | `200` status object | `400 invalid_request`, `503 server_stopping` |
| `POST /v1/requests` | `201` admission object | `400 invalid_request`, `409 busy`, `503 server_stopping` |
| `PUT /v1/requests/{id}/audio` | `200 {"text": "..."}` | Every code except `busy` |
| `DELETE /v1/requests/{id}` | `204`, no body | `400 invalid_request` |
| `POST /v1/stop` | `202`, no body | `400 invalid_request` |

The server checks every request in this order and answers with the first rule
that applies:

1. Unknown path or method: `400 invalid_request`.
2. A body on an endpoint other than PUT, judged from the headers alone
   (`Transfer-Encoding`, or `Content-Length` other than 0): `400
   invalid_request` with `Connection: close`. The server does not read that body.
3. `DELETE` gets `204` and `POST /v1/stop` gets `202`, in every server state.
4. After a stop has been accepted: `503 server_stopping`.
5. The endpoint's own rules below.

### `GET /v1/status`

No request body. Content-free: no audio, text, vocabulary, paths or PIDs.
Checking status never starts a server, loads a model or touches model files.

```json
{"api_version":1,"state":"idle","worker":"absent","network_isolation":"required","config_generation":"fixture-config-1","settings":{"editor_mode":"standard","model_id":"qwen3-asr-0.6b","language":"en"},"audio":{"encoding":"f32le","sample_rate_hz":16000,"channels":1},"limits":{"json_body_bytes":65536,"result_body_bytes":65536,"audio_bytes":19200000},"deadlines":{"upload_start_seconds":5,"reservation_seconds":330,"computation_seconds":120,"client_wait_seconds":125}}
```

- `api_version`: integer, `1` for this contract.
- `state`: `idle`, or `busy` while a request holds the slot or a retired
  worker is still being reaped.
- `worker`: `absent` (no worker process) or `running` (a worker process is owned:
  starting, loading, warm or computing). It is the server's view of its own
  child, not a worker self-report.
- `network_isolation`: the mode frozen at startup, `required` or `disabled`.
  `required` here is the selection, not evidence of enforcement.
- `config_generation`: opaque token for the configuration frozen at server
  startup, with the request-ID syntax below. It is not a hash of the vocabulary.
- `settings.editor_mode`: `standard` or `vim`. `settings.model_id`: the
  configured manifest alias, an opaque string to clients. `settings.language`:
  a string, `en` for the alpha; there is no configuration key for it.
- `audio`, `limits` and `deadlines`: the fixed v1 values shown, as integers
  (`encoding` a string). They describe this document's constants; a change to
  any of them is a new API version. Clients use this document's values.

### `POST /v1/requests`

Reserves the single active slot, before the app starts the microphone or the
CLI starts decoding. The request has no body. There is no queue and no
preemption, and a rejected request never disturbs the active one.

```json
{"request_id":"fixture-request-1","config_generation":"fixture-config-1","model_id":"qwen3-asr-0.6b"}
```

Request IDs are generated by the server: random, opaque, case-sensitive, 1–128
ASCII characters from `[A-Za-z0-9_-]`, with at least 128 bits of randomness.
`config_generation` and `model_id` equal the values in `GET /v1/status` for the
same server. The 5-second upload-start deadline begins when the `201` is sent.

### `PUT /v1/requests/{id}/audio`

The upload connection owns the request (see Ownership and cancellation).

- Request headers: `Content-Type: application/octet-stream` exactly, and either
  `Transfer-Encoding: chunked` (the app streams from recording start) or one
  `Content-Length` body (the CLI). The body is canonical audio, below.
- After the general checks, the server checks that the ID names a reservation
  waiting for its upload, else `404 request_not_found`. A PUT that passes this
  check has claimed the request, and every later failure ends the request. The
  server then rejects a wrong `Content-Type` with `400 invalid_request`, and a
  declared `Content-Length` over 19,200,000 with `413 invalid_audio` before
  reading the body. A PUT with neither framing header has an empty body,
  which is `400 invalid_audio`. A second PUT for the same ID gets `404
  request_not_found` and does not disturb the first.
- The end of the body (the final zero-length chunk, or the last `Content-Length`
  byte) starts inference. The response is `200 {"text": "..."}` or an error.
- The server may respond before the body ends, for invalid audio, the cap,
  `DELETE`, stop or the reservation deadline. The client then stops sending and
  treats that response as final.
- Every response to this PUT carries `Connection: close`, and the server closes
  the connection after it. An upload connection serves exactly one request.
- The server sends the PUT's terminal response only after the request has
  released the slot, and after reaping the worker when the request retired it.
  A client that has the response can admit its next request at once.

Result text:

- The text is the worker's text unchanged: Unicode, newlines and surrounding
  whitespace are preserved. The one exception is whitespace-only text (Python
  `str.isspace()`), which becomes `""`. The server does not sanitize text:
  control, invisible and bidi characters pass through. How text is displayed or
  made safe is up to each client.
- `{"text":""}` is successful no-speech. It authorizes no review, no Copy and no
  CLI output. Clients do not normalize text again.
- The whole serialized response, `{"text":"..."}` in the encoding above, must be
  at most 65,536 bytes; otherwise `500 result_too_large`. Escapes count, as the
  fixtures' `result_size_cases` show. The worker's `result` frame carries the
  same text inside an envelope under its own 65,536-byte cap, so in practice the
  worker limit is reached first and the REST check is a backstop. The
  `result_size_cases` test the server's response encoder directly.

### `DELETE /v1/requests/{id}`

Explicit cancellation from any connection. `204` with no body for an active,
terminal, expired, unknown or malformed ID, and while stopping. A `204` is not
proof that the request existed, and it is sent without waiting for cleanup:
admission can stay `busy` until a retired worker is reaped (about 2 s at most).
If the request's upload connection is still open, that PUT gets `409 cancelled`.

### `POST /v1/stop`

No request body. Invalidates any active work, stops admission and returns
`202` with `Content-Length: 0`. The server then reaps the worker, removes its
socket and exits. `202` means shutdown started, not that it finished; `hagig
stop` waits for the socket and lock to be released. A repeated stop also gets
`202`. An upload in progress gets `503 server_stopping`. The server keeps
answering on its socket, under the rules above, until it has sent the responses
for active work, reaped the worker and removed the socket; after that, clients
see a refused connection.

## Canonical audio and upload validation

Audio is mono, 16,000 Hz, 32-bit IEEE float little-endian PCM (`f32le`). The
body is nonempty, its length is a multiple of 4, every sample is finite and in
[-1.0, 1.0] (both ends included; -0.0 and subnormals are valid), and the total is
at most 19,200,000 bytes (4,800,000 samples, 300 seconds).

Chunk boundaries carry no meaning. The server validates samples as bytes
arrive, carries an incomplete trailing sample into the next chunk, and counts
every byte against the cap. It fails at once on the first bad sample or the
first byte over the cap, and fails an empty or misaligned body at its end.
`Content-Length` over the cap is rejected before reading. The engine receives
exactly the body bytes. Clients never send file paths, vocabulary, model paths
or configuration overrides, and neither side writes audio to disk or logs.

## Deadlines

| Deadline | Duration | Measured from → to | On expiry |
| --- | --- | --- | --- |
| Startup/connect | 5 s | client spawns or connects → `GET /v1/status` answers | client reports a startup failure; no spawn loop |
| Upload start | 5 s | `201` sent → server receives the PUT request head for that ID | server releases the slot; a late PUT gets `404 request_not_found` |
| Reservation | 330 s | `201` sent → end of the upload body | `504 deadline_exceeded` on the open upload |
| Computation | 120 s | end of body → result ready; covers worker launch, ready line, model load and inference | `504 deadline_exceeded`; the worker is terminated and reaped |
| Client wait | 125 s | client finishes sending the body → response head received | client closes the connection, which cancels, and reports `deadline_exceeded` locally |
| Client exchange | 5 s | client sends status, admission, `DELETE` or stop → response received | generic failure; never retried automatically |

The server enforces the reservation deadline itself, because uvicorn has no
body-read timeout. These are failure bounds, not acceptable latencies. A result
that arrives after 5 s but within 125 s is a normal success. If an admission
reply times out, the client cannot know the ID; the upload-start deadline
releases that reservation.

## Lifecycle, ownership and cancellation

The server request lifecycle is the state machine in TDD §7.

- One admitted request exists at a time, including while it records. Each
  terminal transition releases the audio buffer and the slot exactly once.
- Cancellation is any of: `DELETE`, loss of the upload connection, the
  upload-start or reservation deadline, or stop. Once the PUT has started, its
  connection owns the request. Closing it, including the kernel closing a
  crashed app's socket, cancels at once and no response is delivered. Closing
  any other connection cancels nothing.
- The handler waits for the worker's reply and for client disconnect together;
  a disconnect cancels the worker.
- Cancellation invalidates the request first. If the worker is launching,
  loading or computing for that request, the server then terminates and reaps it
  (there is no in-band cancel, because inference cannot be interrupted safely),
  admission stays `busy` until the reap, and the next request starts a fresh
  worker. A warm idle worker is not touched by cancelling a request that has not
  reached it. A result that arrives after invalidation is discarded, never sent.
- A worker crash fails only that request. There is no automatic retry; the
  worker restarts lazily on the next request.
- A successful worker stays warm with its loaded model. There is no idle
  eviction; stop is the release mechanism.

Both sides must invalidate, because the server cannot control what the client
shows:

- The client cancels by first invalidating its local generation and discarding
  pending display or delivery, then closing the upload connection. It does not
  wait for any acknowledgment. Anything that arrives after local invalidation is
  discarded, including a `200` that was already in flight.
- If the user stops or cancels before admission returns, the client never opens
  the upload or starts capture, and sends `DELETE` for any `201` it later gets.
- The app opens the upload immediately after `201`, before the microphone
  starts and including any permission prompt, and writes chunks as capture
  produces them.
- Bytes already delivered cannot be recalled, and a Copy already made cannot be
  undone.

## Client rules

Compatibility. Before admission the client reads `GET /v1/status`. Only two
answers are not `incompatible_api`: `503 server_stopping`, which is that
failure, and a `200` JSON object where `api_version` is 1, every field above is
present with its type, and `state`, `worker`, `network_isolation` and
`editor_mode` hold known values. Anything else, including any other listed
error code, is `incompatible_api`: a server that no longer speaks v1 answers
`/v1/status` differently. On `incompatible_api` the client does not admit,
restart or stop the server.

Admission. If the `201`'s `config_generation` or `model_id` differs from the
status the client read, the server restarted in between. The client sends
`DELETE`, does not capture, and reports a generic failure.

Outcomes. Outside `GET /v1/status`, the client classifies each response:

- `201` from `POST /v1/requests` with a string `request_id` of the request-ID
  syntax above and string `config_generation` and `model_id`: `admitted` (then
  the Admission rule).
- `204` from `DELETE`: `cancel_acknowledged`. `202` from `POST /v1/stop`:
  `stop_acknowledged`. Clients ignore any body on these.
- `200` from PUT with a string `text`: nonempty is `text` (review in the app;
  the text plus one newline on stdout in the CLI), `""` is `empty`.
- An error status with a `code` the error table lists for that status, on any
  endpoint: `failure` with that code.
- Anything else is `generic_failure`, never success. That includes an unknown
  code, a known code with the wrong status, a malformed `201`, a `200` without a
string `text`, a success status from a different endpoint, a
  non-JSON body, an oversized body, or a connection that fails before a response
  head is read.

An upload client may be writing a chunk when an early error response and close
arrive; depending on timing it reads the response or sees a failed write. A
failed write before a response head is a `generic_failure`. It is never treated
as success, and the client never retries the upload.

CLI exit codes are TDD §9's: `text` and `empty` exit 0, `failure` with `busy`
exits 3, other failures, generic failures and `incompatible_api` exit 1, and
interruption exits 130. stdout carries only the text; stderr carries stable
codes only.

## Worker pipe protocol

The server launches the worker with `asyncio.create_subprocess_exec` in a new
session (`start_new_session=True`), and talks to it only over the worker's stdin
(server to worker) and stdout (worker to server). There are no sockets and no
`multiprocessing`. stderr is discarded. On macOS in required mode, the command is
prefixed with `/usr/bin/sandbox-exec -f <absolute path of seatbelt-v1.sb in the
installed package>`. Launch hygiene (environment allowlist with the offline and
telemetry settings, `close_fds`, working directory `/`) is in TDD §1–§2.

Isolation fails closed, with no fallback to disabled mode:

- In required mode on a platform without an implementation (always Linux), the
  server does not launch, and the request fails `isolation_unavailable`.
- In required mode on macOS, a missing `sandbox-exec`, a failed launch, or a
  worker that exits or closes stdout before the ready line also fails
  `isolation_unavailable`, because the server cannot tell a refused policy from
  another launch failure. In disabled mode the same events are `worker_failed`.

### Ready line

The worker's first stdout bytes are exactly `HAGIG-WORKER-READY-v1\n` (22
bytes, ASCII), written and flushed before it imports any engine. Any other
bytes are `worker_failed`. The computation deadline covers this wait.

### Frames

After the ready line, every message is a frame:

```text
kind:u8 | length:u32 big-endian | payload[length]
```

- Kind 1, both directions: a UTF-8 JSON object of 1–65,536 bytes, in the same
  compact encoding as REST, with no duplicate keys, integer numbers only and
  exactly the fields listed below. The only nesting is the `vocabulary` array of
  strings. Unknown or missing fields, deeper nesting, and strings that cannot be
  encoded as UTF-8 (lone surrogates) are malformed.
- Kind 2, server to worker only: canonical PCM as above, 4–19,200,000 bytes, a
  multiple of 4. A kind-2 header from the worker is a protocol failure.
- Both sides validate the kind and length before allocating, and read fully
  across partial reads. An unknown kind, an out-of-range length, invalid UTF-8
  or JSON, any parser error (including recursion limits), or EOF mid-frame is a
  protocol failure.

### Messages

```json
{"type":"load","version":1,"generation":1,"engine":"qwen3-asr","model_dir":"/absolute/model/dir","vocabulary":["term"]}
{"type":"loaded","generation":1}
{"type":"transcribe","generation":1,"request_id":"fixture-request-1","sample_count":3}
{"type":"result","generation":1,"request_id":"fixture-request-1","text":"Fixture."}
{"type":"error","generation":1,"request_id":"fixture-request-1","code":"worker_failed"}
```

1. The worker starts and writes the ready line.
2. The server sends `load` once per worker process. `version` is 1; `engine` is
   `qwen3-asr` or `mlx-whisper`; `model_dir` is the absolute installed model
   directory; `vocabulary` is the configured term list, possibly empty. The
   vocabulary travels only here, never in arguments or the environment, and must
   fit in the frame cap. The worker imports only that engine, loads the model and
   replies `loaded`, or `error` with `request_id: null`.
3. For each request the server sends `transcribe` and then exactly one kind-2
   frame of `sample_count × 4` bytes. The worker replies `result` or `error`,
   echoing `generation` and `request_id`.

Generation and request-ID matching:

- `generation` is a positive integer the server assigns to each worker process
  it launches, increasing within the server's lifetime. `request_id` is the REST
  request ID.
- The server accepts a reply only when its `type` is the one it expects next,
  its `generation` equals the current worker's, and its `request_id` equals the
  in-flight request's (`null` for `load`).
- A mismatch, a malformed or oversized frame, a stray stdout byte at any time
  (including while idle) or an unexpected EOF fails the in-flight request with
  `worker_failed` and retires the worker. Because the generation changes per
  worker, a stale reply can never match a new request.
- The server never logs, returns or echoes worker bytes it rejected or did not
  expect. Diagnostics record only the failure kind (for example
  `worker_protocol`), never frame contents.

Worker error codes:

| Code | Sent when | REST result |
| --- | --- | --- |
| `model_missing` | `load`: expected files absent | `503 model_missing` |
| `model_invalid` | `load`: a file fails validation or the engine cannot load it | `503 model_invalid` |
| `result_too_large` | `transcribe`: the `result` frame would exceed 65,536 bytes | `500 result_too_large` |
| `worker_failed` | Engine failure, unsupported `version`, or a protocol violation the worker sees | `500 worker_failed` |

Any other code is treated as `worker_failed`.

Before it launches a worker, the server checks, in order: that the configured
model has a published installation (`<id>/current`, else `503 model_missing`),
then isolation as above (else `503 isolation_unavailable`), then that the
installation matches its install record: a private versioned directory holding
exactly the recorded files at their recorded sizes (else `503 model_invalid`).
These checks run once per worker launch and hash nothing. The worker's `load`
hashes every recorded file before it constructs an engine. After any `error` reply the server retires the
worker. A worker stays warm only after `loaded` and `result`.

Lifetime: one request is in flight at a time. The server enforces the
120-second computation deadline on the reply. To retire a worker the server
closes its stdin (the exit request; the worker exits on EOF) and waits up to
1 s for it to exit. If it is still running, the server sends SIGTERM to its
process group and waits up to 1 s more, then SIGKILL to the group if it is
still running. The server always reaps the worker, and sends group signals
only while the worker is unreaped, so the group ID cannot have been reused.
The worker must not leave descendants behind. Cancellation of in-flight work
uses the same sequence immediately.

The worker never logs or writes text, audio, vocabulary or paths to any output
other than protocol frames.

## Shared fixtures

[`tests/fixtures/rest-v1-fixtures.json`](tests/fixtures/rest-v1-fixtures.json)
holds synthetic HTTP exchanges and the expected client outcome for each. pytest
(#45) drives the real server with them; the Swift tests (#46) serve their
responses from an HTTP peer on a Unix socket. They prove codec and state
expectations only, not transcription, isolation or native capture. They contain
no recorded audio, real transcripts or vocabulary. Multi-step orderings
(cancellation races, busy while another request records, recovery after a
crash) are tests in #45 and #46, built from these exchanges by name.

Top-level keys:

- `error_codes`, `client_local_codes`: the tables above, as data.
- `exchanges`: one request and its response each.
- `result_size_cases`: REST response sizes on both sides of the 64 KiB result
  limit, for the server's response encoder.

Each exchange:

- `request`: `method`, `target` and an ordered `headers` list. `body` is one of:
  - `{"empty": true}`: no body.
  - `{"hex": ...}`: sent with `Content-Length`; JSON bodies also give the
    decoded `json`.
  - `{"chunks": [hex, ...]}`: sent with `Transfer-Encoding: chunked`, one chunk
    per item, then the terminating zero-length chunk. With `"open": true` the
    terminator is not sent; the response comes while the body is still open.
  - `{"repeat": {"unit_hex", "count"[, "chunk_units"]}}`: `unit_hex` repeated
    `count` times. With `chunk_units`, it is chunked with that many units per
    chunk and the rest in the last chunk; otherwise it is one `Content-Length`
    body.
  - `{"not_sent": true}`: headers only; the response comes before any body.
- `response`: `status`, `reason`, an ordered `headers` list and a `body`
  (`{"empty": true}`, or the exact bytes as `hex`, with the decoded `json` for
  JSON). The wire bytes are `HTTP/1.1 <status> <reason>\r\n`, `Name: value\r\n`
  for each header, `\r\n`, then the body.
- `consumers`: who uses the exchange. `["client"]` marks exchanges used only by
  client tests: either a response a v1 server never sends, or a twin of a server
  exchange whose request no client sends. `["server"]` marks requests no client
  sends, or states a client test has no use for.
- `client`: the expected client outcome: `compatible`, `incompatible_api`,
  `admitted`, `text` (with `text`), `empty`, `failure` (with `code`),
  `generic_failure`, `cancel_acknowledged` or `stop_acknowledged`. `then:
  "cancel_admitted"` means the client must also send `DELETE` for the ID.
- `given`: the server state that produces the response; absent on client-only
  exchanges. Omitted keys take the defaults below.

| `given` key | Values (default first) |
| --- | --- |
| `state` | `idle`; `reserved` (`fixture-request-1` admitted, upload not opened); `uploading` (its PUT already open); `upload_start_expired` (it missed the 5 s upload start); `stopping` (a stop was accepted; server tests hold this state with a test-only hook that delays listener shutdown and socket removal after the `202`) |
| `worker` | `absent`; `running` |
| `network_isolation` | `disabled`; `required` (status and refusal fixtures only, since Linux refuses required mode) |
| `model` | `installed`; `missing`; `corrupt` |
| `isolation` | `available`; `unavailable` (required mode cannot establish isolation: real on Linux, a test launcher on macOS) |
| `engine` | `{"text":"Fixture."}`; `{"text": ...}`; `{"text_repeat": {"unit", "count"}}` (that text repeated); `crash`; `stall` |
| `during_upload` | none; `delete`, `stop` or `reservation_deadline`, happening while the open PUT body is being sent |

Placeholders: `fixture-request-1` and `fixture-config-1` stand for
server-issued values; server tests substitute the real ones, and check the
fields listed in `server_variable` (JSON pointers) by syntax, with
`content-length` checked against the actual body. `fixture-request-2` is an ID
the server never issued and is sent literally. `qwen3-asr-0.6b` is the model the
test configuration selects.

Server tests require the listed status and body, and each listed response header
with its value (names are case-insensitive). They ignore `reason` and extra
headers such as `date`. For valid uploads, the engine must receive exactly the
body bytes.

Client tests drive the client against a peer that serves the response bytes
exactly as given. The peer checks the client's method, target (placeholders
replaced), `Content-Type`, and the framing that client uses (chunked for the
app, `Content-Length` for the CLI), but not chunk boundaries, body bytes or
`Host`. It sends the response after the request body ends, except for `open`
bodies, where it responds after the request head and first chunk and then
closes. `not_sent` bodies appear only in server exchanges.
