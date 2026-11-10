# Python backend guidance

Read the root guidance, [constitution](../docs/CONSTITUTION.md) and
[technical design](../docs/technical/tdds/01-mvp.md) (§1–§7 and §9–§13 are the
contract) first. This directory is a scaffold: configuration, paths, the server
lock and WAV decoding are implemented and tested; the server, worker, CLI
commands, model installation and bundling are not (#45, #47, #48).

## Layout and boundaries

- One uv project and one package, `hagig`, with two entry points: `hagig`
  (`hagig.cli:app`, the CLI and later the internal server command) and
  `hagig-worker` (`hagig.worker:main`, also run as `python -I -m hagig.worker`).
  Do not split packages per process.
- `config.py`: TOML configuration (§3). `paths.py`: XDG locations, private
  runtime directory, socket path and `ServerLock` (§3, §5). `wav.py`: bounded
  WAV decoding into canonical PCM (§9). `logging.py`: content-free structlog.
- `app.py`: FastAPI factory with no routes or lifespan yet; docs, OpenAPI and
  FastAPI's native OpenTelemetry are disabled. `cli.py` and `worker.py` are stubs: every
  CLI command exits 1 with `not_implemented` on stderr, and the worker exits 1
  without writing to stdout, which is reserved for the worker protocol.
- `routers/`, `controllers/`, `services/` and `dtos/` are the template's
  layering (routers -> controllers -> services), empty until #45.
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
  overrides. A missing file or table means defaults: `editor.mode = "standard"`,
  `inference.network_isolation = "required"`, `vocabulary.terms = []` and
  `model.id = "qwen3-asr-0.6b"`.
- The model default is PROVISIONAL, not a chosen default: §13 leaves the default
  engine and Qwen size to a physical-Mac run. It lives only in
  `config.PROVISIONAL_DEFAULT_MODEL_ID`.
- Model aliases: `qwen3-asr-0.6b`, `qwen3-asr-1.7b`, `whisper-large-v3-turbo`
  (the #47 manifest IDs). Whisper is rejected unless the platform is Darwin on
  arm64 (`model.id model_unsupported_on_platform`).
- Strict pydantic models with unknown keys forbidden. Codes: `unknown_key`
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
real filesystem, lock and socket behavior. Add an e2e tier with the first
end-to-end test. Tests never touch the network, the
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
`httpx` is approved but not added until the CLI client needs it.

Direct runtime dependencies: fastapi, `uvicorn[standard]`, structlog, pydantic,
typer, numpy. Development: pytest, ruff, ty. Build backend: hatchling
(unpinned in `[build-system]`, resolved by uv when building the project).

Locked transitives (see `uv tree --frozen`): annotated-doc, annotated-types,
anyio, click, colorama (Windows only), h11, httptools, idna, markdown-it-py,
mdurl, opentelemetry-api, pydantic-core, pygments, python-dotenv, pyyaml, rich,
shellingham, starlette, typing-extensions, typing-inspection, uvloop,
watchfiles, websockets; dev adds iniconfig, packaging and pluggy. Native wheels:
numpy, pydantic-core, httptools, uvloop, watchfiles, pyyaml, ruff and ty.

Findings to carry forward (source inspection only, not runtime observation):

- fastapi 0.162 requires `opentelemetry-api` and has native telemetry that turns
  on when a global provider exists or `FASTAPI_OTEL_AUTO_CONFIGURE=true`.
  No OpenTelemetry SDK or exporter is installed, and `create_app` disables all
  native telemetry (tested with the auto-configure variables set).
- `uvicorn[standard]` installs websockets, watchfiles and python-dotenv; the
  contract has no WebSockets, reload or env files, so #45 must run uvicorn with
  WebSockets off, no reload, no env file, `access_log=False` and no default
  `log_config` (its access and error loggers bypass the structlog allowlist).
- FastAPI's default `RequestValidationError` handler echoes rejected input in
  422 bodies; #45 must install a content-free handler before adding routes.
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
  with the macOS-only temp-dir test skipped). Hosted ubuntu-24.04 and macos-15
  results are the exact-head `python-backend.yml` runs on the #43 branch and PR.
