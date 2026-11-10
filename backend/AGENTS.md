# Python backend guidance

Read the root guidance, [constitution](../docs/CONSTITUTION.md) and
[technical design](../docs/technical/tdds/01-mvp.md) (§1–§7 and §9–§13 are the
contract) first. Configuration, paths, the server lock, WAV decoding, the REST
server, the worker protocol and the CLI (`start`, `status`, `stop`,
`transcribe`) are implemented and tested with a test-only fake engine (#45).
Model manifests, `hagig model install` and load-time model checks are
implemented (#47). Real engines (#49) and bundling (#48) are not. Fake-engine
success is not transcription evidence.

## Layout and boundaries

- One uv project and one package, `hagig`, with two entry points: `hagig`
  (`hagig.cli:app`, the CLI) and `hagig-worker` (`hagig.worker:main`). Clients
  spawn the server as `python -I -m hagig.server` and the server launches the
  worker as `python -I -m hagig.worker`. Do not split packages per process.
- `config.py`: TOML configuration (§3). `paths.py`: XDG locations, private
  runtime directory, socket path and `ServerLock` (§3, §5). `wav.py`: bounded
  WAV decoding into canonical PCM (§9). `logging.py`: content-free structlog.
- `server.py`: the server process (lock, stale socket, 0600 bind, uvicorn,
  stop and signal shutdown). `app.py`: FastAPI factory; docs, OpenAPI, redirects
  and FastAPI's native OpenTelemetry are disabled, and FastAPI's input-echoing
  error handlers are replaced. `routers/v1.py`: the five endpoints and the
  `Precedence` middleware for the contract's routing and body rules, which
  matches requests against the router's own routes.
- `services/requests.py`: the single request slot, deadlines, streaming audio
  validation and cancellation. `services/supervisor.py`: worker launch,
  generations, reply matching and retirement/reaping.
- `contract.py`: the fixed REST v1 values (limits, deadlines, error codes and
  their statuses, the request-ID syntax and the JSON encoding), shared by the
  server, the CLI and the worker pipe. `framing.py`: worker frames, message
  schemas, `LOAD_CODES` and `OFFLINE_ENV`, shared by server and worker. Both
  are stdlib only, because the worker imports them. `worker.py`: the engine `Protocol`, the fixed `ENGINES` table
  and the worker loop. `launcher.py`: worker argv per isolation mode and the
  environment allowlist.
- `manifest.py` and `manifests/<alias>.json`: the tracked model manifests.
  `models.py` (stdlib only; the worker imports it): installation layout,
  install record and the load-time checks. `installer.py`: `hagig model
  install`, the only network code.
- `client.py`: the CLI's httpx client (`trust_env=False`), one method per
  endpoint, each classifying its response into a PROTOCOL.md outcome. `cli.py`:
  commands, including `model install`.
- `controllers/` and `dtos/` from the template stay empty; the routers call
  services directly.
- `src/launcher/seatbelt-v1.sb` is the macOS worker policy, kept byte-identical
  from the Rust backend. `PROTOCOL.md` and `tests/fixtures/*-fixtures.json` are
  owned by #44.
- The server never imports an inference engine, PyTorch or model code. Keep
  portable code free of AppKit, Accessibility and permission logic.
- Inject effects through explicit inputs, per the root guidance:
  `ensure_runtime_dir` takes the environment mapping, platform, uid, `tmp_root` and the macOS temp-dir
  lookup; `load_config` takes `apple_silicon`. Tests use these, not mocks.
- Never log or echo audio, transcripts, vocabulary, raw configuration, paths or
  OS/library error text. Every error here is a stable code (plus a field name
  for configuration) and is raised outside its `except` block, so no
  content-bearing exception is attached as `__cause__` or `__context__`.

## Contracts implemented here

**Configuration** (`load_config(path)`, path from `config_file(os.environ)`):

- Read only from the file with `tomllib`; there are no environment-variable
  overrides. `model.id` is required and has no default (owner decision,
  2026-11-10): a missing file, `[model]` table or `id` fails with
  `model.id missing`. Every other field defaults: `editor.mode = "standard"`,
  `inference.network_isolation = "required"`, `vocabulary.terms = []`.
- #45's CLI must turn `model.id missing` into an actionable stderr line that
  says to set `[model] id` in the config file. It may name the config path but
  never prints file content.

  ```toml
  # $XDG_CONFIG_HOME/hagig/config.toml (default ~/.config/hagig/config.toml)
  [model]
  id = "qwen3-asr-0.6b"  # or "qwen3-asr-1.7b"; "whisper-large-v3-turbo" on Apple Silicon

  [editor]
  mode = "standard"  # optional; "vim"

  [inference]
  network_isolation = "required"  # optional; "disabled" is an explicit opt-out

  [vocabulary]
  terms = ["Hagig", "Ghostty", "Qwen", "Amp"]  # optional
  ```
- Model aliases: `qwen3-asr-0.6b`, `qwen3-asr-1.7b`, `whisper-large-v3-turbo`
  (the #47 manifest IDs). Whisper is rejected unless the platform is Darwin on
  arm64 (`model.id model_unsupported_on_platform`).
- Strict pydantic models with unknown keys forbidden. Codes: `missing`, `unknown_key`
  (names the containing table, or `<root>`, never the key, which is user input),
  `invalid_value`, `invalid_type`, `too_many`, `too_long`, `too_large`,
  `model_unsupported_on_platform` (the `IssueCode` Literal). File-level codes
  are `config_unreadable`, `config_too_large` (over 1 MiB) and `config_syntax`
  (including invalid UTF-8 and nesting deep enough to hit the recursion limit).
  Validating without `load_config`'s platform context rejects Whisper. `ConfigError.code` is
  `config_invalid` when `issues` lists field/code pairs.
- Vocabulary: a list of strings, each stripped; empty terms and terms containing
  control or line/paragraph-separator characters are `invalid_value` (terms go
  into model prompts). At most 200 terms (`too_many`), 100 characters each
  (`too_long`) and 16 KiB of UTF-8 in total (`too_large`). Errors name
  `vocabulary.terms` or `vocabulary.terms[<index>]`.
- Open engine limit: Whisper's prompt window (about 224 tokens) is smaller than
  these caps allow. #49 owns how the engine handles it; validation here does not.

**Paths** (`ensure_runtime_dir` creates; the others only compute):

- Config `$XDG_CONFIG_HOME/hagig/config.toml`, models
  `$XDG_DATA_HOME/hagig/models`, defaulting under `$HOME`. Relative XDG values
  are ignored, per the XDG spec; a missing or relative `HOME` is `home_unavailable`.
- Runtime: `$XDG_RUNTIME_DIR/hagig` when that base is an owner-only (0700)
  directory; otherwise macOS uses `hagig` inside `confstr(_CS_DARWIN_USER_TEMP_DIR)`
  (via ctypes; Python 3.12 does not expose it) and fails closed with
  `runtime_dir_unavailable` if the OS returns nothing, never `$TMPDIR`; other
  platforms use `/tmp/hagig-<uid>`. The directory is created 0700. An existing
  object that is a symlink, not a directory, not ours or not exactly 0700 is
  `runtime_dir_unsafe` and is left untouched.
- `socket_path` is `<runtime>/server.sock`, rejected with `socket_path_too_long`
  unless it fits `sun_path` (104 bytes on macOS, 108 elsewhere) with its NUL.
- `ServerLock.acquire(runtime)` opens `<runtime>/server.lock` with
  `O_NOFOLLOW`, requires a regular 0600 file we own (`lock_file_unsafe`) and
  takes `flock(LOCK_EX | LOCK_NB)`, returning None when another holder has it.
  A symlink (ELOOP) is `lock_file_unsafe`; other open or lock failures, such as
  a missing directory, are `lock_unavailable`.
  `release()` closes the descriptor; the file is never unlinked, so every
  contender locks the same inode. Stale-socket handling belongs to #45.

**WAV** (`read_wav(path)` / `decode_wav(data)`):

- RIFF/WAVE with 16-bit integer or 32-bit float PCM, plain or
  WAVE_FORMAT_EXTENSIBLE with exactly those subformats and matching valid bits;
  mono or stereo; 16, 44.1 or 48 kHz; at most five minutes of frames.
- Output is mono 16 kHz float32: int16 is scaled by 1/32768, stereo channels are
  averaged, and other rates are resampled by deterministic linear interpolation
  that never extrapolates past the last input and applies no anti-aliasing
  filter (see `wav._resample`).
- Strict structure: the RIFF size must match the file, `fmt ` must precede a
  single `data`, chunks must fit, sizes must agree with the format. Unknown
  chunks are skipped with their pad byte.
- Codes: `wav_unreadable`, `wav_malformed`, `wav_unsupported`, `wav_empty`,
  `wav_too_long` (duration, or a file over `MAX_FILE_BYTES`, the largest
  supported data plus 1 MiB) and `wav_invalid_samples` (float samples that are
  not finite or exceed full scale). The file is opened read-only and at most
  `MAX_FILE_BYTES + 1` bytes are read.

**Logging**: `configure_logging()` writes JSON to stderr and keeps only
allowlisted field names (`logging.CONTENT_FREE_FIELDS`) with scalar values;
other keys, exceptions and structured values are dropped. It does not inspect
scalar values, so event names and codes must be fixed strings. Call it once at
the process entry point; it only covers structlog, not stdlib loggers.

**Server** (`hagig.server.run(env, *, launcher, deadlines, grace_seconds,
before_exit)`):

- Loads configuration, ensures the runtime directory and takes `ServerLock`;
  a loser exits 0 so its client attaches to the winner. Only the holder removes
  a stale socket, and only one that is a socket we own (else `socket_unsafe`).
  It binds `server.sock` itself under umask 0177, checks it is 0600 and ours,
  and passes it to uvicorn (`ws="none"`, `lifespan="off"`, `access_log=False`,
  `log_config=None`, no server header). There is no TCP listener. uvicorn's,
  asyncio's and FastAPI's stdlib loggers get a `NullHandler`.
- `POST /v1/stop`, SIGTERM and SIGINT all stop: invalidate active work, answer
  it, reap the worker, run `before_exit` (tests hold the stopping state with
  it), remove only our socket inode, exit 0 and release the lock.
- Everything else follows `PROTOCOL.md`; `tests/e2e/test_rest_fixtures.py`
  replays every server exchange in the shared fixtures byte for byte.
- Request IDs and `config_generation` are `secrets.token_urlsafe(24)` (192 bits).
  Deadlines (`Deadlines`) and the retirement step (`grace_seconds`) are explicit
  inputs so tests do not wait 330 or 120 s.
- The audio buffer is held in memory once, validated per chunk as it arrives
  in stream order (a bad sample before the cap byte is `400`, the first byte
  over the cap `413`, whatever the chunking), and written to the worker; the request releases it and the slot in one
  `finally`, after any retired worker is reaped.

**Worker** (`hagig.worker.run(stdin, stdout, engines)`):

- Writes `HAGIG-WORKER-READY-v1\n` before constructing any engine, then
  `load` → `loaded`/`error`, then `transcribe` + one PCM frame → `result`/`error`.
  An unsupported version or engine, an engine exception, a wrong generation or
  sample count, or an unencodable result is `worker_failed`; a result envelope
  over 64 KiB is `result_too_large`. Malformed input exits 1 without replying.
  EOF at a frame boundary (the exit request) exits 0.
- `main()` sets the offline variables, moves fd 1 to stderr so stray prints
  cannot corrupt the protocol, and serves the real `ENGINES`. Its modules
  (`hagig.engines.qwen3_asr`, `hagig.engines.mlx_whisper`) arrive with #49;
  until then selecting one fails `load` with `worker_failed`.
- The server launches it with `asyncio.create_subprocess_exec` in a new
  session, `close_fds`, `cwd="/"`, stderr to `/dev/null` and an environment of
  `HOME`, `TMPDIR`, `PATH=/usr/bin:/bin` and the four offline/telemetry
  variables. Vocabulary travels only in `load`.
- Isolation (`Launcher.argv`): disabled runs the command as is. Required on
  macOS prefixes `/usr/bin/sandbox-exec -f <absolute src/launcher/seatbelt-v1.sb>`,
  resolved relative to the package (#48 must ship the profile at the same
  relative place); a missing `sandbox-exec` or profile, a failed launch or no
  ready line (including part of one) is `isolation_unavailable`; in
  disabled mode the same is `worker_failed`. Required anywhere else refuses before
  launching. Model checks wrap isolation: see **Models** for the order.
- Retirement: abort stdin (the exit request), wait 1 s, SIGTERM the process
  group, wait 1 s, SIGKILL the group, poll until reaped, then drain stdout. Group
  signals are sent only while unreaped. Any stdout byte or EOF while idle
  retires the worker. There is no automatic retry; the next request launches
  a fresh worker.

**Models** (TDD sections 2 and 4; manifests, `models.py`, `installer.py`):

- One manifest per alias in `src/hagig/manifests/` (package data): `engine`,
  `apple_silicon_only`, `source` (publisher, repository, 40-hex revision,
  license and its URL, and the `resolve/<rev>/` download base) and `files`
  (plain name, size, SHA-256) for every file the engine reads. Whisper adds
  `conversion`: Apple's `ml-explore/mlx-examples` `whisper/convert.py` at a
  pinned commit with its size and SHA-256, its arguments (`--dtype float16`)
  and its output names. Parsing is strict (`manifest_invalid`); a pickle
  suffix is `manifest_pickle` and no `.safetensors` among downloads or
  outputs is `manifest_no_safetensors`; missing package data is
  `manifest_unavailable`. A manifest's identity is the SHA-256 of its bytes
  (`Manifest.digest`, a private attribute only `parse_manifest` sets).
  Pins (2026-11-10): the spike's revisions and weight hashes, cross-checked
  against Hugging Face's LFS SHA-256; small files hashed from the pinned
  revisions. Repository `README.md` and `.gitattributes` are not installed.
- Layout under `$XDG_DATA_HOME/hagig/models/`: `.install.lock` (persistent
  0600, `flock` non-blocking; never unlinked), `.staging-*` (an install in
  progress), `<id>/current` → `v-<32 hex>` (a relative symlink, replaced
  atomically) and `<id>/v-<hex>/`, the immutable installation: the engine's
  files, flat, plus `hagig-install.json` (manifest ID, manifest SHA-256, every
  file's size and SHA-256). The models directory, `<id>` and the version
  must be real directories owned by the user and not group- or
  other-writable (installer: `model_dir_unsafe`; load: `model_invalid`).
  #49 loads `transformers` `from_pretrained(dir)`
  for Qwen and mlx-whisper's `load_model(dir)` (`config.json`,
  `weights.safetensors`) for Whisper from the directory the worker receives.
- `hagig model install <id>` (CLI process only). The CLI owns the preflight:
  unknown IDs (exit 2), Whisper off Apple Silicon (exit 2) and Whisper
  without the `mlx-whisper` extra (`engine_not_installed`, exit 1). The
  installer then takes the lock (`install_in_progress` when held). A valid installation is re-hashed and kept
  (`already_installed`). Otherwise every manifest file is fetched with httpx
  (`trust_env=False`, no Hub client, cache or token, `Accept-Encoding:
  identity`) into a fresh staging directory, refusing a declared length other
  than the manifest size and stopping at the first byte past it, and hashing
  while streaming. Redirects are followed by hand to HTTPS `huggingface.co`,
  `*.hf.co`, `*.huggingface.co` or `raw.githubusercontent.com` only, at most
  five. Whisper's `convert.py` is verified, then run as `<this python> -I`
  with the worker's offline environment and stdio to `/dev/null` (30 min
  bound); exactly the expected outputs must appear and are hashed into the
  record (written with one buffered write, so a short write raises). Publish:
  rename the staging content to `v-<hex>`, then replace `current`; other
  `v-<hex>` versions and temporary links are pruned, and anything else in
  `<id>/` (for example a pre-#47 flat layout) is left alone. Failures leave
  the previous `current` untouched; the next install removes leftovers. Codes:
  `download_origin_refused`, `download_redirect_refused`, `download_failed`,
  `download_size_mismatch`, `download_hash_mismatch` (each with the manifest
  file name), `conversion_failed`, `conversion_output_invalid`,
  `model_dir_unsafe`, `lock_file_unsafe`, `install_failed`, `interrupted`
  (exit 130). stderr prints `<code>` or `<code>: <file>`, and progress as
  `<event> [<file>]`. Any filesystem error is `install_failed` (one boundary
  in `install`), and any httpx failure, including invalid redirect URLs, is
  `download_failed`.
- Load time, never acquiring anything. Before launching a worker the server
  checks, in PROTOCOL.md's order: `<id>/current` exists (else
  `model_missing`), isolation, then `installed_model`: a `v-<hex>` link, a
  record of at most 64 KiB matching the tracked manifest (ID, digest, file
  set, and sizes and hashes for unconverted files) and a directory holding
  exactly the recorded regular files at their recorded sizes (else
  `model_invalid`). Files are opened `O_NOFOLLOW | O_NONBLOCK`, so a planted
  FIFO is refused rather than blocking. It hashes nothing, so it costs one readlink, one small
  read and one `lstat` per file per worker launch, never per warm request.
  The worker's `load` then hashes every recorded file (`verify_installation`)
  before constructing an engine: an absent file is `model_missing`, any other
  difference `model_invalid`. That re-reads the weights once per worker
  launch (seconds for 1.5–4 GB), the price of catching same-size corruption.
- The server sends the resolved `v-<hex>` path, so a warm worker keeps its
  version while an install publishes another; only the next launched worker
  sees it. A worker loading while an install prunes its version fails closed.

**CLI** (`hagig start|status|stop|transcribe`):

- `start` and `transcribe` attach to a compatible server, or spawn
  `python -I -m hagig.server` once (new session, stdio to `/dev/null`) and poll
  `GET /v1/status` for 5 s. Before spawning they validate configuration; a
  missing `model.id` prints `config_invalid: model.id missing; set [model] id
  in <path>` and exits 2.
- `status` prints `stopped` or the status JSON and never spawns. `stop` sends
  `POST /v1/stop` and waits up to 15 s for the socket to go and the lock to be
  free (`stop_timeout`); on an absent server it exits 0. On `incompatible_api`
  neither stops nor admits.
- `transcribe`: status, admit (DELETE and `generic_failure` if the generation or
  model changed), decode the WAV, upload with `Content-Length`, wait up to 125 s
  for the response head. stdout is only the text plus a newline; `""` prints
  nothing. Exit 0 text/empty, 1 failures, 2 configuration or WAV errors (the
  reservation is cancelled first), 3 `busy`, 130 Ctrl-C (the upload connection
  closes and a DELETE is sent). Ctrl-C during the admission exchange is held
  until the 201 is read (at most its 5 s timeout), because the server is busy
  from its 201 on and only the ID lets the CLI cancel at once. stderr carries
  stable codes only.
- `tests/integration/test_client_fixtures.py` drives the client with every
  client fixture exchange from a peer that serves the response bytes exactly.

**Updating a checkout.** The server outlives the CLI and is reused by any
client that sees `api_version` 1, and it launches each new worker from the
current tree. Run `hagig stop` before pulling, rebasing or rebuilding, so the
server and worker code never come from different revisions. If a client
reports `incompatible_api`, `hagig stop` will not stop that server: stop it
with the build that started it, or end the process holding
`<runtime>/server.lock`.

## Developer commands

Run from `backend/`. uv selects Python 3.12 from `.python-version` and
`requires-python = "==3.12.*"`. `uv.lock` is committed; `[tool.uv]
exclude-newer = "1 week"` comes from the template. Changing dependencies
(`uv lock`, `uv add`) is an explicit network step and needs the approvals below.

Run `just --list`. The recipes wrap `uv run --frozen` ruff, ty and pytest;
`just gate` is the fast check and `just gate-expensive` is what CI runs.

`.github/workflows/python-backend.yml` (push to main, python-backend and `py/**`,
and pull requests, path-filtered) runs `uv sync --frozen` and the
`gate-expensive` commands directly (no just on the runner) on ubuntu-24.04 and
macos-15, with SHA-pinned checkout and `astral-sh/setup-uv` (uv 0.12.9).

Tests: `tests/unit` for pure parsing and validation, `tests/integration` for
real filesystem, lock and socket behavior, `tests/e2e` for the real server and
CLI over the real socket. `tests/support/` holds the test-only fake engine
(`fake_worker.py`, the real `hagig.worker.main` with a fake table and a
frame-tampering writer, scripted through a control directory),
`harness.py` (isolated XDG users, raw socket requests) and
`serve_fake.py`, which runs the real server with that worker command injected.
Neither is importable from the package, configuration, the CLI or the
environment. Tests never touch the network, the
real `/tmp/hagig-<uid>` or user configuration; derive expected values
independently (for example the stdlib `wave` module decodes `speech.wav`).

## Template provenance

Generated from `https://github.com/mattjmcnaughton/templates`, subdirectory
`templates/python-service`, at `72a28b9be899c6ccd39f06f8482d55e460556acd`, with
copier 9.19.1:

```sh
uvx copier@9.19.1 copy --trust --defaults <clone>/templates/python-service <out> \
  -d project_name=hagig \
  -d 'project_description=Privacy-first local voice-to-text server, worker and CLI' \
  -d author_name=mattjmcnaughton -d author_email=me@mattjmcnaughton.com \
  -d license=MIT -d include_database=false -d include_clients=false \
  -d enable_otel=false -d include_technical_docs=false -d include_product_docs=false
```

The template ships no answers-file template, so `.copier-answers.yml` is written
by hand and `copier update` is not wired up. The answers, including author
`mattjmcnaughton <me@mattjmcnaughton.com>` and license MIT, are owner-confirmed.

Licensing: the repository is MIT under the root `LICENSE` (owner decision,
subsuming #38). `pyproject.toml` declares `license = "MIT"`, but the package
carries no license text of its own: the generated `backend/LICENSE` was removed,
and `license-files` cannot point at `../LICENSE` (PEP 639 forbids `..`). #48 must
copy the root `LICENSE` into the bundle.

After generation:

- Removed: `LICENSE` (see Licensing), `.dockerignore`, `.env.example`, `Dockerfile`, `docker-compose.yml`,
  `tests/conftest.py`, the `tests/e2e` tier and `.gitkeep` files,
  `.github/workflows/ci.yml`, `docs/` (`api.md`, `architecture.md`,
  `development.md`, `adrs/`; the TDD owns these), `CLAUDE.md` and its `AGENTS.md`
  symlink (this file replaces them), `routers/health.py` (`/healthz` and
  `/readyz` are not in the `/v1` contract) and the `external` test marker.
- Rewritten: `config.py` (TOML instead of pydantic-settings), `logging.py`
  (stderr, allowlist, no environment settings), `app.py` (no routes, docs and
  telemetry off, no metadata, lifespan or module-level app), `README.md`, `.gitignore` (database and Docker entries dropped).
- Edited: `pyproject.toml` (pydantic, typer and numpy instead of
  pydantic-settings; entry points; Python 3.12 pin) and `justfile` (`--frozen`,
  single-run `test-all`, no external-test recipes).
- Template defects: `ty>=0.12` is unsatisfiable (ty is 0.0.x), so the bound is
  `ty>=0.0.1`; the generated description line exceeded ruff's 88 columns, so the
  description answer was shortened.

## Dependency approval and inventory

Ask the owner before adding anything outside the root `AGENTS.md` starting set.
For this run the owner also approved the template's `uvicorn[standard]` and
hatchling, Python 3.12 and SHA-pinned `astral-sh/setup-uv` and `actions/cache`.
`httpx` (starting set) was added by #45 for the CLI client.

Direct runtime dependencies: fastapi, `uvicorn[standard]`, structlog, pydantic,
typer, numpy, httpx. Development: pytest, ruff, ty. Build backend: hatchling
(unpinned in `[build-system]`, resolved by uv when building the project).

Engines (#47) are extras of the one package, pinned in the one `uv.lock`:
`qwen3-asr` = transformers 5.22.2 and torch 2.15.0 (Linux from the explicit
`pytorch-cpu` index, `2.15.0+cpu`; macOS from PyPI); `mlx-whisper` = mlx
0.32.4 and mlx-whisper 0.4.3, marked `sys_platform == 'darwin' and
platform_machine == 'arm64'` (an empty extra elsewhere). Plain `uv sync
--frozen` (CI, the server and portable tests) installs neither. The bundle
must run `uv sync --frozen --no-dev --extra qwen3-asr --extra mlx-whisper`.
transformers 5.22.2 is newer than `exclude-newer`, so `exclude-newer-package`
admits it alone. Engine transitives: huggingface-hub 2.4.0 (with httpx2
2.16.0, httpcore2 2.16.0, truststore 0.10.5, hf-xet 1.8.0, filelock 4.2.7,
fsspec 2026.9.0; httpx2-jsfetch 1.0 on Emscripten only), tokenizers 0.23.3,
safetensors 0.8.0, regex 2026.9.29, jinja2 3.1.6, markupsafe 3.0.4, networkx
3.7, sympy 1.14.0, mpmath 1.3.0, setuptools 84.2.1, tqdm 4.70.1; on Apple
Silicon also mlx-metal 0.32.4, numba 0.68.1, llvmlite 0.50.0, scipy 1.18.1,
tiktoken 0.14.0, requests 2.34.2, urllib3 2.8.0, charset-normalizer 3.5.2 and
more-itertools 11.2.1. huggingface-hub, hf-xet (native Xet client), requests
and tiktoken contain network code: the worker sets the offline variables and
Seatbelt is the backstop. The installer's own code uses only httpx. The
converter it runs is not sandboxed: `convert.py` imports mlx_whisper, which
imports huggingface-hub (`load_models.py`) and tiktoken (`tokenizer.py`), and
it contains a named-model download, a Hub fallback and `upload_to_hub`. With
a local `--torch-name-or-path` and no `--upload-name` none of them is
reached (source inspection of the pinned file and mlx-whisper 0.4.3), and it
runs with the offline variables set. Not yet inspected beyond this inventory
(constitution §6).

Locked transitives (see `uv tree --frozen`): annotated-doc, annotated-types,
anyio, click, colorama (Windows only), h11, httptools, idna, markdown-it-py,
mdurl, opentelemetry-api, pydantic-core, httpcore and certifi (both pure
Python, from httpx; certifi is a CA bundle, unused over the Unix socket, and
`trust_env=False` keeps proxies and `.netrc` out), pygments, python-dotenv, pyyaml, rich,
shellingham, starlette, typing-extensions, typing-inspection, uvloop,
watchfiles, websockets; dev adds iniconfig, packaging and pluggy. Native wheels:
numpy, pydantic-core, httptools, uvloop, watchfiles, pyyaml, ruff and ty.

Findings to carry forward (source inspection only, not runtime observation):

- fastapi 0.162 requires `opentelemetry-api` (since fastapi 0.142.0; 0.141.1 is
  the last release without it) and has native telemetry that turns on when a
  global provider exists or `FASTAPI_OTEL_AUTO_CONFIGURE=true`. `create_app`
  disables all native telemetry (tested with the auto-configure variables set).
  Accepted as an inert transitive: API only. No OpenTelemetry SDK or exporter
  may enter the lock; if one does, revisit this decision (owner, 2026-11-10).
- `uvicorn[standard]` installs websockets, watchfiles and python-dotenv; the
  contract has no WebSockets, reload or env files, so the server runs uvicorn
  with `ws="none"`, no reload, no env file, `access_log=False` and
  `log_config=None`, and silences its stdlib loggers.
- FastAPI's default `RequestValidationError` and `HTTPException` handlers echo
  input; `create_app` replaces both with `400 invalid_request`.
- `decode_wav` holds float64 working copies (about 4.5 times the input at the
  116 MB cap). Fine in the CLI; revisit if decoding moves into the server.
- A grep of the installed runtime packages for `urllib.request`, `http.client`,
  `socket`, `requests` and `httpx` imports found none outside the HTTP stack
  (starlette, uvicorn, anyio, h11, httptools, websockets). This is a finite
  source check, not a privacy certification (constitution §6).

## Evidence log

Record actual commands, hosts and results here; keep Linux, hosted macOS and
physical-Mac evidence separate. A workflow file is not evidence that a job ran.

- 2026-11-10, Linux orb (Debian 12, x86_64, CPython 3.12.14 from uv 0.12.9),
  #43 scaffold: `just gate-expensive` passed (ruff format, ruff check, ty, pytest
  with the macOS-only temp-dir test skipped).
- 2026-11-10, hosted `python-backend.yml`
  [run 42837802389](https://github.com/mattjmcnaughton/hagig/actions/runs/42837802389)
  at `4451e63`: ubuntu-24.04 (x86_64, system CPython 3.12.3) and macos-15
  (arm64 VM, macOS 15.8.2, system CPython 3.12.10) each passed ruff, ty and
  155 tests with 1 skip. On macOS the real per-user temp-dir test ran; the
  socket-bind boundary test skipped (runner temp path too long), so a real
  104-byte bind is unexercised. Portable checks only: not Seatbelt, inference
  or bundle evidence. Later heads: see the branch's runs.
- 2026-11-10, Linux orb (Debian 12, x86_64, CPython 3.12.14 from uv 0.12.9),
  #45 server, worker and CLI with the test-only fake engine: `just
  gate-expensive` passed. Mutation proof: 20 lifecycle, framing, isolation and
  CLI claims each failed under a recorded semantic mutation and passed again
  when it was reversed. Fake-engine results are not transcription evidence; the
  hosted macos-15 Seatbelt launch test shows only that the worker starts and
  speaks over its pipes under `seatbelt-v1.sb`, not network denial (#49).
