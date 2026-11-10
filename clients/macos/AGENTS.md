# Native shell and screenshot workflow

## Experimental real client (merged; not accepted dictation)

The #22 editor (PR30) and the #21 capture/socket client (PR32) are merged on main.
The normal shell routes Record/Stop/Cancel to `DictationController`, native
AVAudioEngine/AVAudioConverter capture and the REST API v1 contract in
`backend/PROTOCOL.md` (#44), spoken by `SocketRequest` with swift-server
AsyncHTTPClient over `http+unix://` (#46). Backend and wire changes are owned by
the backend; there is no Swift TOML parser, inference engine or normal-operation
fake fallback. Older synthetic-only descriptions below are historical evidence
notes.

Normal operation requires the paired bundled backend (see the local bundle
below) and an explicitly installed model. There is no controlled-helper
fallback. Hosted integration evidence is not physical-Mac acceptance (#21/#23 remain
open). Resolve `hagig` only at `Contents/Helpers/hagig`. Only when no server
answers on the socket (absent, or stale after a crash) does Swift run that helper
once with `start` (in the bundle, the Python CLI's `start`), then retry status
within the one 5 s startup bound. Helper exit 2 (TDD §9 usage/configuration) shows
the configuration issue. The server's lock owns stale-socket cleanup; Swift never
removes or repairs runtime files. No ambient PATH. Swift computes the socket exactly like
`backend/src/hagig/paths.py`: `$XDG_RUNTIME_DIR/hagig/server.sock` when that base
is an owner-only 0700 directory, otherwise `hagig/server.sock` in
`confstr(_CS_DARWIN_USER_TEMP_DIR)` (never `$TMPDIR`), failing closed when the OS
gives none. It requires a 0700 runtime directory and 0600 socket owned by the
user, rejects symlinked runtime directories, and measures the pathlib-normalized
path against the 104-byte `sun_path` limit.

Per request: `GET /v1/status` (compatibility rule, else `incompatible_api`), then
`POST /v1/requests` before the microphone or any permission prompt, then the
chunked `PUT /v1/requests/{id}/audio` opened at once. A `201` whose
`config_generation`/`model_id` differ from the status, or that arrives after
Cancel, is released with `DELETE` and never captured. Capture streams converted
mono 16 kHz f32le chunks into the open upload as it produces them; no recording
buffer is kept. Warning at 4:45, cap at 5:00; Stop and cap share one completion
path, which ends the body. The client waits up to 125 s after the body ends, and
5 s for status, admission and `DELETE`. Unknown codes and malformed replies are
generic failures, never success; `{"text":""}` is no-speech (no review, no Copy).
An early server response ends the request. Cancel/Escape invalidates main-actor
visibility first, then closes the upload without ending its body and without
waiting for any reply. A failed or empty capture is discarded the same way.
Device/configuration change and revoked access discard the request. Copy/Cut
remain the preserved #22 currentHostOnly routes. The header shows the status's
`settings.model_id` after admission, otherwise "Local model".

The synthetic editor harness is now explicit:
`swift run HagigShell --synthetic-demo`. Only that flag creates demo controls;
normal launch does not show a fake result or request Accessibility/Input Monitoring.
The owned synthetic interaction driver passes this flag and remains synthetic
editor evidence, not microphone/socket or ordinary uninstrumented acceptance.

Native commands remain `swift build` and `swift test` with Xcode16.4. The package
pins AsyncHTTPClient exactly (1.28.0, the newest release Xcode 16.4's SwiftPM can
load without the tracing packages) with a committed `Package.resolved`; SwiftNIO
and BoringSSL compile from source, so CI jobs allow longer than ten minutes. Tests
exercise controlled admission/late-result cancellation, converter/cap bounds and
an explicit test-only HTTP/1.1 peer on a real Unix socket that serves
`backend/tests/fixtures/rest-v1-fixtures.json` byte for byte (read from the
checkout, never copied into Swift): every client exchange, disconnects, the 5 s
exchange bound, a six-second result, runtime-path rules and both cancel orderings
at the delivery boundary. They use no personal audio/text.
Ready proof remains two shared-view PNGs; representative gallery is now34 images
(17 states × light/dark), adding admission, near-cap and recoverable client errors.
Inspect Ready before every representative image, then execute AX/keyboard/pointer
checks and inspect a complete moving-pointer clip. Hosted checks never establish
physical microphone/TCC/grant-denial-rebuild, real inference or second-device
clipboard acceptance. Linux source checks are not native compilation/render proof.
No native #21 evidence is established merely by these source changes.

Read the root guidance, constitution, MVP PRD and TDD. The reviewed UI source is
`docs/product/prototypes/`; its browser checks do not validate this native client.
This is an experimental real-client candidate, not an accepted installed alpha.

## Boundaries

- `HagigPresentation/Presentation.swift`: in-memory presentation/actions, request
  identity guard for simulated late results, and synthetic fixtures. This is not
  authoritative server state, a Swift inference backend, or an IPC implementation.
- `HagigPresentation/HagigView.swift`: reusable real SwiftUI surface. The shell and
  capture executable must use this same view; never duplicate screenshot UI.
- `HagigShell`: AppKit status item/popover, real Record/Stop/Cancel and explicit
  current-host-only Copy/Cut. Intentional capture requests Microphone permission
  after backend admission. No automatic paste, key injection or model downloads.
  Demo controls require `--synthetic-demo`.
- `HagigScreenshots`: renders shared views through AppKit `NSHostingView` bitmap
  caching at 2×, including AppKit-backed controls that `ImageRenderer` omits, in
  light/dark appearances with activity animation disabled through the shared
  view's `animateActivity` input. This does not override or test the read-only
  system Reduce Motion setting; the shell always respects that setting.
  Its Copy effect is inert. The copied
  image is a presentation fixture, not evidence of a clipboard operation.
- Swift will own macOS interaction; Python owns server, inference/worker and CLI.
  Do not recreate another thread's uncommitted inference experiments here.

Do not add real user text/audio to fixtures, logs or screenshot artifacts. This is
a PUBLIC repository: Actions logs/artifacts are not a private review channel.
Local clipboard managers can retain explicit Copy content; current-host-only is
not a general retention guarantee.

## Dependency boundaries

Apply the root convention without adding a protocol for every view or model.
`HagigView` receives its Copy closure explicitly, and `Presentation.copy(using:)`
accepts the write effect rather than accessing `NSPasteboard` itself. The shell
supplies the real clipboard writer; the screenshot harness supplies an inert
closure. Preserve this separation. Use a Swift protocol when an effect needs a
cohesive multi-operation contract, not just to wrap a single closure. Substitutes
test presentation outcomes; native clipboard and interaction claims still require
the platform evidence below.

## Commands (macOS required)

From `clients/macos`, with Xcode 16.4 selected:

```sh
export DEVELOPER_DIR=/Applications/Xcode_16.4.app/Contents/Developer
swift build
swift test
swift run HagigShell
swift run HagigScreenshots proof captures
# Only after proof's PNGs have been downloaded and visually inspected:
swift run HagigScreenshots states captures
```

Use `swift run HagigShell --synthetic-demo` for the editor demo. Click the
menu-bar microphone; use Simulate recording → Simulate
release → Simulate result → explicit Copy or Dismiss. Escape cancels active work.
Preview error and Quit live below the shared surface. No global shortcut exists.
Normal `swift run HagigShell` has no paired Contents/Helpers/hagig and must fail
safely, not substitute demo success. Use the bundle for real integration.

## Local bundle (#48): app plus bundled Python backend

Python, managed with uv, owns the server, worker and CLI (`backend/`); Swift owns
the app. `clients/macos/bundle.sh` assembles both into one ignored, ad-hoc-signed
`clients/macos/.build/Hagig.app`. This is bundle feasibility for #23, not its
final recipe or physical-Mac acceptance.

Prerequisites, from the clone root on an Apple Silicon Mac (native arm64 shell):
Xcode 16.4 (Apple supports it on macOS 15.3 through 26.1.x; on a newer macOS stop
rather than edit the version check) and uv (the version `python-backend.yml`
pins, 0.12.9). uv downloads the locked wheels and, when absent, the uv-managed
Python 3.12; that `uv sync` is the build's only network step. The 3.12 patch
release bundled is the one that uv version selects (the smoke prints it). No Homebrew,
`/Applications` copy, certificates or notarization credentials are needed.

```sh
export DEVELOPER_DIR=/Applications/Xcode_16.4.app/Contents/Developer
bash clients/macos/bundle.sh build   # or `run` to also open the new bundle
open clients/macos/.build/Hagig.app  # launch an already built bundle
```

Layout (paths relative to the bundle):

```text
Hagig.app/Contents/Info.plist
Hagig.app/Contents/MacOS/HagigShell
Hagig.app/Contents/Helpers/hagig                      # sh: execs the interpreter below
Hagig.app/Contents/Resources/LICENSE                  # root LICENSE (the package has none)
Hagig.app/Contents/Resources/python/bin/python3.12    # uv-managed python-build-standalone
Hagig.app/Contents/Resources/python/lib/python3.12/   # stdlib, precompiled
Hagig.app/Contents/Resources/python/lib/python3.12/site-packages/   # the locked environment
    hagig/ (with seatbelt-v1.sb and manifests/*.json)  torch/ transformers/
    mlx/ mlx_whisper/ numba/ scipy/ fastapi/ uvicorn/ numpy/ ...
```

How it is built, and why:

- `sync_backend` in `bundle.sh` is the one place that picks the environment:
  `UV_PYTHON_PREFERENCE=only-managed uv sync --frozen --no-dev --no-editable
  --extra qwen3-asr --extra mlx-whisper` into a staging directory: #47's command
  plus the two flags relocation needs (a wheel install, not an editable `.pth`
  link to the checkout; and only a uv-managed interpreter).
- uv environments are not relocatable: a venv's `pyvenv.cfg` records its
  interpreter's absolute path, uv adds a `_virtualenv` shim, and the project's
  `direct_url.json` names the checkout. So the bundle does not ship the venv.
  It copies the managed interpreter itself (python-build-standalone finds its
  prefix from its own location) and copies the venv's `site-packages` into that
  interpreter's own `site-packages`, minus the shim and `direct_url.json`. Every
  Hagig process runs `python -I` (`cli.SERVER_COMMAND`, `launcher.WORKER_COMMAND`),
  which ignores `PYTHON*` variables and the user site and sees exactly those
  packages. `-I` still runs `.pth` files and `sitecustomize`/`usercustomize`, so
  the build refuses any of them, after removing uv's shim and setuptools'
  build-time `distutils-precedence.pth`.
  Headers, docs, build configuration, pip/ensurepip, IDLE, Tcl/Tk and
  the other `bin/` scripts (build-host shebangs) are left out.
- The non-editable install puts the Seatbelt profile inside the package, at
  `site-packages/hagig/seatbelt-v1.sb`, through a hatch wheel `force-include` in
  `backend/pyproject.toml` (a Hagig-owned path, not a generic top-level
  directory). `launcher.SEATBELT_PROFILE` uses that installed copy first and
  falls back to the source tree's `backend/src/launcher/seatbelt-v1.sb`, where
  the file stays, for checkouts. `bundle.sh` refuses to publish without the
  profile, and required mode still fails closed with `isolation_unavailable` if
  neither exists.
- `compileall` with `unchecked-hash` precompiles the stdlib and packages, so no
  process writes `__pycache__` into the signed bundle (the smoke re-verifies the
  seal after a run). Recorded source names use a neutral prefix.
- Signing is local and ad hoc, inside out: every Mach-O file under
  `Resources/python` (the interpreter, `.so` and `.dylib`), then the helper and
  `HagigShell`, then the app, then `codesign --verify --deep --strict`.
  `install_name_tool` removes SwiftPM's `@loader_path` rpath from the shell only.
  Ad-hoc signing is not Developer ID, notarization, Gatekeeper approval, a TCC
  grant or permission stability across rebuilds, and without the hardened
  runtime it gives no resistance to same-user dyld injection.
- `Contents/Helpers/hagig` resolves `Contents` from its own path (not a symlink
  to it), sets `UV_OFFLINE=1` and `UV_PYTHON_DOWNLOADS=never` defensively and
  execs `python3.12 -I -B` on `hagig.cli`. It uses no uv, PATH, PYTHONPATH or
  checkout path. The app runs it with `start` only when no server answers; exit 2
  is a configuration error (for example a missing `[model] id`).
- Known build-host residue: python-build-standalone's `_sysconfigdata*.py`
  records the build machine's uv Python directory. Nothing loads it to run
  Hagig (it serves builds); the smoke only rejects references to the checkout.

Configuration and models. `model.id` is required (see `backend/AGENTS.md`):

```toml
# $XDG_CONFIG_HOME/hagig/config.toml (default ~/.config/hagig/config.toml)
[model]
id = "qwen3-asr-0.6b"  # or "qwen3-asr-1.7b"; "whisper-large-v3-turbo" on Apple Silicon
```

Installing a model is a separate explicit network step through the paired CLI,
`.../Contents/Helpers/hagig model install <id>` with one of those three IDs
(#47; models land in `$XDG_DATA_HOME/hagig/models/<id>/current`). The bundle
build asserts it carries the three manifests, but no model install has been run
from the bundle. Real engines arrive with #49, so this bundle cannot transcribe
yet; without a model every request answers `model_missing`.

Stop and relaunch. The server is per user and outlives the app. Before
rebuilding or replacing a bundle: Quit the shell, coordinate with other clients
of the same server, then intentionally run that bundle's
`Contents/Helpers/hagig stop` and require success (the builder never stops it).
Move the **whole** stopped bundle aside to an unused path (for example
`clients/macos/.build/Hagig.previous.app`), build again and relaunch with `open`.
Never replace individual files under a live server; keep the old bundle for
rollback and stop the new one before restoring it. An existing output is always
refused (including symlinks). A preexisting `bundle.lock` is refused; after an
interruption, confirm no builder remains, then `rmdir` it. Failed staging is
cleaned. If a client reports `incompatible_api`, stop that server with the build
that started it.

Checks:

```sh
python3 clients/macos/test_bundle.py           # Linux/macOS stand-ins, NOT native evidence
bash clients/macos/smoke-bundle.sh /abs/moved/Hagig.app   # macOS, bundle outside the checkout
bash clients/macos/bundle-proof.sh /abs/moved/Hagig.app /abs/new/evidence
```

What each check proves (the scripts own the mechanics):

- `smoke-bundle.sh`, on a bundle moved outside the checkout, under `env -i` with
  private XDG paths and a config setting `model.id`: every Mach-O is signed,
  arm64 and loads only system or bundle-relative paths; no `Resources` or
  `Helpers` file names the checkout (the Swift shell may embed source paths as
  diagnostic strings); the helper starts a server that is the bundled
  interpreter and maps no code from elsewhere; `GET /v1/status` answers over the
  socket with `network_isolation: required`; `transcribe speech.wav` answers
  `model_missing`; `stop` works; the seal still verifies afterwards; and it
  prints the interpreter version and sizes. Without a model the server never
  launches a worker (`model_missing` is checked first), so the smoke runs the
  server's own `Launcher().argv("required")` and `worker_env` with the bundled
  interpreter: `sandbox-exec -f` the in-bundle profile, then the bundled worker,
  which must write its ready line. That shows the profile resolves and the
  worker starts under it, not network denial or inference.
- `bundle-proof.sh` breaks one property per copy and requires the right refusal:
  a `.pth` link to the checkout (the CLI still runs, so runtime success alone
  would miss it), a missing profile (`isolation_unavailable`), an unsigned
  `pydantic_core` extension (which macOS still loads in this unhardened process,
  so only the build and the smoke enforce signing), and no `hagig` package for the app test
  (`serverUnavailable`). The original then passes both checks again.
- `BundledBackendTests` (opt-in: absolute `HAGIG_BUNDLED_APP` and
  `HAGIG_INTEGRATION_WAV`; both unset skips, one set fails) is the app against
  the bundled server: `DictationController` and the real `SocketRequest` start it
  through `Contents/Helpers/hagig`, a file capture streams `speech.wav` through
  the production converter (not a microphone), and the result is the
  `.issue(.modelMissing)` state with no transcript. Without `model.id`, the
  helper's exit 2 shows `.issue(.configuration)` and starts no server. Each test
  stops only its own server and prints `BUNDLED_BACKEND_CLEANUP_COMPLETE`.

`macos-build.yml`'s `bundle-smoke` job runs them all on macos-15 after moving the
bundle to `$RUNNER_TEMP/relocated app` and hiding uv's private interpreter and
cache directories. `bundle-proof.sh` makes its copies as APFS clones (`cp -c`). It uploads text logs only, never bundle bytes. Hosted runs are
not physical-Mac launch, LaunchServices, TCC, microphone or rebuild-permission
acceptance.

`bash clients/macos/client-proof.sh /absolute/new/evidence` runs preregistered
client-only candidate/mutant/restoration in a disposable worktree with unchanged
tests/digests and identical commands. Existing Xcode/Swift/Python only, no assets;
CI provides the hard timeout. Compile/setup/zero-test failures do not count.
Coverage: admission/late-result guards, auto-stop, PCM cap/warning, failed-capture
discard, status compatibility, the 5 s exchange bound, the 125 s result wait,
DELETE for a late admission, Cancel closing the upload without ending its body,
the first-launch status poll, the upload opening before the permission prompt,
the per-user temp-dir fallback (not `$TMPDIR`), the helper start on a stale
socket, the result wait anchored at the end of the body and unknown codes as
generic failures; not every protocol claim.

Native evidence: [run 40509803030](https://github.com/mattjmcnaughton/hagig/actions/runs/40509803030)
executed build, three passing presentation tests, two Ready renders and 26 state
renders on macOS 15.7.9 arm64 / Xcode 16.4 / Swift 6.1.2. Both Ready PNGs and every
gallery state/appearance were inspected for native controls, readable synthetic
labels, contrast and clipping. The checked-out PR merge ref was
`10689509db97a5ab720c91c9c6161bc427e48de9` for branch head
`2ce42efe8cfd96e6337dff3e92afea452a51514d`. Earlier ImageRenderer output was rejected
because it substituted prohibited-symbol placeholders for native buttons; the
working path uses AppKit hosting/caching. These commands ran on the hosted Mac,
not the Linux orb. Shell interaction, animation and physical-Mac checks remain
unexecuted; still images are not evidence of those behaviors.

## GitHub-hosted Mac evidence, in order

1. Obtain explicit owner permission to commit/push and open a PR. No publishing
   or remote execution is authorized by this guidance.
2. The path-filtered `macos-build.yml` runs on `pull_request` (and matching pushes
   to main). Normal PR CI builds/tests, then runs
   `swift run --skip-build HagigScreenshots proof captures` and uploads exactly
   the two Ready PNGs plus OS, architecture, Xcode, Swift and checked-out commit
   metadata. **No merge or manual dispatch is required for this first proof.**
   GitHub may require maintainer approval for a contributor's Actions run.
   On PRs, the default checkout is GitHub's PR merge ref; the recorded `HEAD`
   identifies the actual code tested, not necessarily the branch head SHA.
3. Download the PR CI artifact and inspect both images with `view_media`, checking
   actual content, legibility, dimensions and clipping. Successful upload alone
   is not a render-quality pass. Fix build/test/render failures on the PR and
   inspect new artifacts before accepting the broader evidence set.
4. After the proof render/upload succeeds, the same normal CI job runs
   `swift run --skip-build HagigScreenshots states state-captures` and uploads the
   bounded 26-image gallery separately. Inspect the Ready proof first, then every
   gallery image before merging. This needs no manual dispatch. The workflow
   collects the gallery automatically; human inspection remains a merge gate.
5. Optional reruns remain manual in `macos-screenshots.yml`. GitHub requires
   a `workflow_dispatch` definition on the default branch before it can be
   dispatched; register it only through separately authorized review/merge, after
   the PR-first proof gate. Once registered, `--ref <branch>` selects that branch's
   implementation. Obtain explicit dispatch permission. `scenario=proof` remains
   available for a small rerun; it is not the bootstrap path.
   Manual dispatch is not authorized for this initial PR verification.
6. Expect 26 gallery PNGs: ready, recording,
   transcribing, fallback, copied, cancelled, no speech, and six error states,
   each light/dark. Inspect every image. Copy/Dismiss must fit, fallback must show
   only the synthetic fixture, recording must have no transcript, and errors must
   provide a recovery path. Share the final inspected images in the report.

Read-only PR artifact discovery/download examples from the repository root:

```sh
gh run list --workflow macos-build.yml --event pull_request --branch <reviewed-branch> --limit 5
gh run download <run-id> --dir <review-directory>
```

Only after registration, proof inspection and explicit dispatch authorization:

```sh
gh workflow run macos-screenshots.yml --ref <reviewed-branch> -f scenario=states
```

Both workflows select `macos-15` and the installed `/Applications/Xcode_16.4.app`
explicitly; neither follows `macos-latest`. GitHub's image itself is mutable: record
the environment, do not claim an immutable OS pin or Apple Silicon acceptance.
Actions are SHA-pinned, credentials are not persisted, permissions are read-only,
`macos-build.yml` jobs time out after 20 minutes (90 for the bundle smoke, which
builds the app twice and compiles, signs and checks the engines, and 60 for
client semantics, which
rebuilds per experiment), and artifact retention is three days. Its build-test job
fails if `swift package resolve` would change the committed `Package.resolved`.
The manual `macos-screenshots.yml` still allows ten minutes, which may be too
short now that SwiftNIO and BoringSSL compile from source. The manual
scenario enum is bounded and never accepts arbitrary fixture content or commands.

## Evidence limits

`swift test` tests presentation actions, cancellation in recording/transcribing,
late and old-generation results, empty text, explicit/failed Copy, Dismiss/reset,
and error recovery. These are not XCTest app-interaction tests: they do not click
buttons, assert accessibility trees, or test keyboard routing in a running app.
Native PNGs establish view rendering only, not popover sizing/positioning, focus,
animation, keyboard behavior, or macOS clipboard behavior. Reduced-motion stills
do not establish the pulse/spinner animation.

Before calling interaction complete, run the shell on macOS, exercise keyboard and
pointer Copy/Dismiss/Escape and error recovery, record/inspect a short interaction
clip, and inspect accessibility names/focus order. Physical-Mac acceptance remains
necessary for nonactivating recording feedback, global shortcuts, microphone and
permissions, Ghostty/Chrome input identity/races, clipboard locality on a second
Apple device, native packaging, privacy and performance. This shell deliberately
does not solve those spikes. Do not claim the ordinary interactive NSPopover is
production-safe nonactivating feedback.

## Editable review (#22, merged)

`ReviewEditor.swift` embeds a real plain NSTextView in the shared HagigView, with
native selection, accessibility, scrolling and in-memory undo. Standard remains
default. `Presentation(editorMode:)` / `begin(editorMode:)` accept the eventual
validated server setting; the real client takes it from `GET /v1/status`
`settings.editor_mode` during reservation, and there is no Swift TOML parsing.
The demo controls' explicitly synthetic mode picker applies to the next request.
The existing 26-image gallery retains its count: fallback is Standard; copied is
Vim Normal with a synthetic edited multiline Unicode fixture. No new render or
interaction evidence has been established merely by adding those fixtures.

The agreed bounded table (TDD §8) implemented for native verification:

| Area | Keys |
| --- | --- |
| Modes | Normal initially; i/a Insert before/after cursor; Escape Normal; v character Visual, V line Visual; visible label |
| Motion | h/j/k/l, w/b/e, 0/$, gg/G, numeric counts |
| Changes | x, dd, dw, cw (enters Insert) |
| Register | yy, p; deletes/yanks/paste use only the ephemeral register |
| History | u, Ctrl-R; native Cmd-Z / Cmd-Shift-Z also available |
| Native | Cmd-A; Cmd-C selection; Cmd-X selection Cut; Copy all / Cmd-Shift-C entire current edited text; native paste / Cmd-V |
| Enter / exit | Enter only inserts in Standard/Insert, never submits; Escape in review never dismisses; explicit Dismiss / Cmd-Shift-D |

This is NOT full Vim: no ex, plugins, macros, dot-repeat or external editor.
Vertical motions follow logical lines, not wrapped display rows. Words group
Unicode letters/numbers/underscore, punctuation and whitespace. Motions and edits
use grapheme boundaries, converting to UTF-16 for AppKit. Counts saturate at 9999;
register paste refuses amplification beyond a 1 MiB buffer. Unsupported keys in
Normal are inert. Standard/Insert retain native text input and accessibility.

This editor expands the earlier shell Copy-only boundary to explicit Copy/Cut:
both use the single `LocalClipboard` currentHostOnly writer. No result, edit,
internal Vim operation, reset or Dismiss writes to the clipboard. Failed Cut
preserves text; empty Copy is inert. Context menu exposes only Cut/Copy/Copy all/
Paste/Select all; inherited drag/Services/rich-text selection exporters are
disabled rather than allowed to bypass the guarded writer. Native paste reads
only into review. Reset/new request synchronously discards the attached editor,
register and undo, invalidates its generation and removes the shared view.

AppKit's separate kill buffer is not review-local. Line/paragraph/mark deletion
therefore selects and replaces through native text editing without invoking the
inherited kill implementations; native `yank:` and the alternate `yankAndSelect:`
key binding are inert. This does not disable the bounded Vim in-memory register.
The regression uses a separate ordinary NSTextView as a receiver so merely
blocking Hagig's yank cannot hide accidental writes into AppKit's kill buffer.

`swift test` adds actual text-view key/responder-action tests with isolated real
pasteboards, not simulated backend or mock editor tests. These still do not prove
pointer/focus/accessibility routing in the running shell. Run them on macOS,
inspect Ready then every gallery image, and record/inspect native Standard/Vim
editing, selection, Copy/Cut, undo, Dismiss and keyboard focus. Second-device
Universal Clipboard and owner physical-Mac checks remain acceptance gates.
