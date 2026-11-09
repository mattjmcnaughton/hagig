# Native shell and screenshot workflow

## Experimental real client (merged; not accepted dictation)

The #22 editor (PR30) and the #21 capture/socket client (PR32) are merged on main.
The normal shell routes Record/Stop/Cancel to `DictationController`, native
AVAudioEngine/AVAudioConverter capture and the #9 public socket contract
(`backend/PROTOCOL.md`). Backend and wire changes are owned by the backend; there
is no Swift TOML parser, inference engine or normal-operation fake fallback.
Older synthetic-only descriptions below are historical evidence notes.

Normal operation requires the paired real backend, an explicitly installed model
and native helper packaging (see the local experiment below). Bundle assembly
requires explicit prepared native input, never a controlled-helper fallback.
Hosted integration evidence is not physical-Mac acceptance (#21/#23 remain
open). Resolve `hagig` only at
`Contents/Helpers/hagig`; the helper starts/attaches with `start` (no fake flags).
It owns runtime locking/stale-socket cleanup; Swift validates the same inherited
XDG_RUNTIME_DIR or TMPDIR, private directory/socket and peer UID. No ambient PATH.

Capture begins only after matching admission and microphone grant. Audio stays
in memory as bounded mono16k f32le; warning at4:45, cap at5:00. Stop and cap share
one completion path. Cancel/Escape invalidates main-actor visibility before
disconnect/engine teardown. Device/configuration change and revoked access discard
the request. Copy/Cut remain the preserved #22 currentHostOnly routes.

The synthetic editor harness is now explicit:
`swift run HagigShell --synthetic-demo`. Only that flag creates demo controls;
normal launch does not show a fake result or request Accessibility/Input Monitoring.
The owned synthetic interaction driver passes this flag and remains synthetic
editor evidence, not microphone/socket or ordinary uninstrumented acceptance.

Native commands remain `swift build` and `swift test` with Xcode16.4. Added tests
exercise controlled admission/late-result cancellation, converter/cap bounds and
explicit test-only Unix peers (including a six-second delayed result, busy,
fake-service rejection and malformed framing). They use no personal audio/text.
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
- Swift will own macOS interaction; Rust owns server, inference/worker and CLI.
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

## Prepared native bundle (#21 experimental integration)

From the clone root on an Apple Silicon Mac, native arm64 shell and Xcode 16.4,
use an absolute already prepared Contents directory. The #9 contract was tested
at db18603fa2fcdfe8d53a1485cf05c5705c639589 with
`backend/tests/prepare_macos_candidate.sh` and Rust 1.90.0. Preparation acquires
native assets/crate sources: it is a separate explicitly approved operation,
never an implicit bundle step. Use that script and `backend/model-manifest.json`
as the source of pins and layout; do not invent new versions/assets here.

```sh
bash clients/macos/bundle.sh run /absolute/prepared/Contents
# Or build only, for iteration/CI:
bash clients/macos/bundle.sh build /absolute/prepared/Contents
# Launch an already built bundle without rebuilding:
open clients/macos/.build/Hagig.app
```

These are alternative build commands, not consecutive commands: an existing
output is always refused (including symlinks). No Homebrew, release download,
`/Applications` copy, certificates or notarization credentials are required.
The default Xcode path is `/Applications/Xcode_16.4.app/Contents/Developer`;
`DEVELOPER_DIR` may select another installation of exactly Xcode 16.4. The builder
does not run Cargo, download native/model assets or install a model. It builds
HagigShell, copies five explicit native files, and signs staged copies inside-out.
Prepared inputs remain unchanged. Output is ignored under `clients/macos/.build/`.

### Local source experiment after the gated merges

Use an Apple Silicon Mac with Xcode 16.4 and Rust 1.90.0 already installed
(`backend/rust-toolchain.toml` selects that Rust toolchain). Apple supports
Xcode 16.4 only on macOS 15.3 through 26.1.x
([system requirements](https://developer.apple.com/xcode/system-requirements)),
and `bundle.sh` requires exactly Xcode 16.4. Check `sw_vers -productVersion`
first: on a newer macOS, stop rather than edit the version check; selecting a
different Xcode is an unapproved toolchain change, not a local workaround. This is an opt-in
experimental build, not adoption or physical-Mac acceptance. Preparation and the
explicit model install below acquire the existing pinned native/model/tokenizer
assets (about 3.15 GB plus locked crate sources); neither app launch nor bundle
assembly acquires or repairs them. No Homebrew, release binary, `/Applications`
installation, public signing or notarization is involved. These commands are a
local recipe, not a claim that they have executed successfully on this head.

From a terminal, clone the merged source, prepare the exact backend in a separate
detached worktree, and assemble a new app. Keep this terminal's variables for
launch, stop and optional cleanup:

```sh
git clone https://github.com/mattjmcnaughton/hagig.git hagig
cd hagig
export DEVELOPER_DIR=/Applications/Xcode_16.4.app/Contents/Developer
prep=$(mktemp -d "${TMPDIR:-/tmp}/hagig-local.XXXXXX")
export RUNNER_TEMP="$prep"
git fetch origin db18603fa2fcdfe8d53a1485cf05c5705c639589
git worktree add --detach "$prep/backend-source" db18603fa2fcdfe8d53a1485cf05c5705c639589
(cd "$prep/backend-source/backend" && bash tests/prepare_macos_candidate.sh)
native="$prep/hagig-issue9-native"
bash clients/macos/bundle.sh build "$native/Contents"
app="$PWD/clients/macos/.build/Hagig.app"
runtime=$(mktemp -d /private/tmp/hg-local.XXXXXX)
export XDG_RUNTIME_DIR="$runtime"
export XDG_CONFIG_HOME="$prep/local-config"
export XDG_DATA_HOME="$native/data"
"$app/Contents/Helpers/hagig" model install parakeet-tdt-0.6b-v2-int8-v1
"$app/Contents/MacOS/HagigShell"
```

Run each command only after its predecessor succeeds; stop and diagnose failure,
never retry with isolation disabled. The foreground terminal launch preserves
the explicit private environment (unlike relying on LaunchServices environment
inheritance). No config file is needed: editor defaults to Standard and isolation
to Required. Use intentional Record, Stop, review/edit, explicit Copy and Dismiss;
the first real Record may ask for Microphone permission. Never grant Accessibility
or Input Monitoring for this path. Known model-quality and #6/#25 privacy gates,
physical microphone/device/permission/rebuild and second-device clipboard checks
remain open. Local clipboard managers/destinations may retain explicit Copy.

Quit the shell before cleanup. Its service is shared by clients using this same
private runtime; coordinate those clients, then stop the paired helper. The model
data is intentionally retained for further experiments until this optional cleanup:

```sh
if "$app/Contents/Helpers/hagig" stop; then
  git worktree remove "$prep/backend-source" && rm -rf -- "$prep" "$runtime"
else
  printf '%s\n' 'Stop failed: retain app, model and runtime; do not dispose or replace them.' >&2
fi
```

Only use those variables in the original terminal with the same exported private
environment. Cleanup removes the dedicated model data, so a subsequent experiment
needs another explicit install; it does not remove the assembled app or clone.
Do not delete or replace app/model bytes under a live service. The whole-bundle
backup/rollback procedure below applies before any rebuild; no automatic upgrade,
service kill, recording history or model acquisition is introduced by launch.

Layout (all paths relative to the bundle):

```text
Hagig.app/Contents/Info.plist
Hagig.app/Contents/MacOS/HagigShell
Hagig.app/Contents/Helpers/hagig
Hagig.app/Contents/Helpers/hagig-worker
Hagig.app/Contents/Helpers/hagig-inference-worker
Hagig.app/Contents/Frameworks/libsherpa-onnx-c-api.dylib
Hagig.app/Contents/Frameworks/libonnxruntime.dylib
```

Bundle identity is `com.mattjmcnaughton.hagig`. The shell starts/attaches through
its paired CLI. CLI/bootstrap must link only system libraries; only the isolated
native helper links inference. Helpers retain `@executable_path/../Frameworks`,
and dylibs retain `@loader_path`. No native loader rewrite or unused C++ dylib.
Model installation is explicit and separate. For five already acquired assets:

```sh
clients/macos/.build/Hagig.app/Contents/Helpers/hagig model install parakeet-tdt-0.6b-v2-int8-v1 --from /absolute/preacquired/assets
```

Default Required isolation is retained; failure never retries Disabled. Missing
model/helper/library must fail, never use fake success or automatic downloads.
#9's functional experimental evidence is not privacy/adoption, signed-app or
physical-Mac acceptance. #6/#25, quality failures and microphone/TCC checks remain
separate gates.

Before rebuilding/replacing any paired bundle: Quit its shell, coordinate
with other clients using the per-user server, then **intentionally** run that
bundle's `Contents/Helpers/hagig stop` and require success. Stop affects shared
work; the builder never does it for you. Move the **whole** stopped bundle to a
new unused backup path (for example `mv clients/macos/.build/Hagig.app
clients/macos/.build/Hagig.previous.app` only if the latter does not exist), then
build again. Never replace individual live helper files. Keep the old bundle
for rollback; quit/stop the new pair before restoring the old one. A preexisting
`bundle.lock` is refused; after interruption, confirm no bundle builder remains
before removing that empty lock directory with `rmdir`. Failed build staging is
disposable and cleaned; any incomplete published output must be inspected and
moved aside, not blindly deleted. No automatic upgrade or service killing exists.

Before signing, Xcode's `install_name_tool` removes SwiftPM's `@loader_path`
search entry from the staged shell only; `/usr/lib/swift` is retained. Native
helper/dylib loader commands remain unchanged. The native smoke still
rejects unexpected dependencies/search paths and verifies actual relocated launch.
Removal failure aborts assembly; the SwiftPM build output is left unchanged.
Nested helpers and the outer app are ad-hoc signed inside-out, then verified.
Ad-hoc signing is not Developer ID, notarization, Gatekeeper approval, TCC grant,
permission stability across rebuilds, or worker-isolation proof. Diagnose launch
or signing failures; do not disable Gatekeeper. Info.plist contains the Microphone
usage description for intentional Record. No Accessibility/Input Monitoring
request. Stable identity alone does not establish TCC continuity; physical
denial/grant/rebuild and public signing/notarization remain acceptance gates.

Checks (from clone root):

```sh
python3 clients/macos/test_bundle.py   # stdlib disposable PATH stand-ins, NOT native evidence
bash clients/macos/smoke-bundle.sh    # macOS only, after build-only above
```

The native smoke copies the bundle away from the checkout into a disposable path
with spaces, checks arm64/scoped loader paths and signatures, validates real
inference/Required/idle service capabilities using private temporary paths,
then launches the relocated shell executable briefly and terminates only that
owned PID. Its cleanup stops only its isolated service and preserves scratch on
stop failure. It does not touch the user's live runtime. It is not a terminal
LaunchServices interaction test or runtime-free physical-Mac installation proof.
`macos-build.yml` keeps the packaging stand-in contracts always on. Its finite
real-backend job is bound to PR32's source repo/branch with a twenty-minute hard
timeout and skips elsewhere (including main), so main runs do not claim native
smoke or real-backend evidence. D27 permitted only that PR32 run to reuse the
pinned native/model/tokenizer acquisition (about 3.15 GB), hash verification and
disposal; it is not permission for downloads on other PR or main builds. Running
it for another branch needs a new explicit owner grant. Linux stand-ins are not
native signing/loader proof. Full #23 acceptance remains blocked on inference
adoption (#6/#25) and owner physical-Mac launch/relocation/TCC/rebuild checks.

Opt-in `RealBackendTests` takes absolute `HAGIG_INTEGRATION_HELPER`,
`HAGIG_INTEGRATION_DATA_HOME` and `HAGIG_INTEGRATION_WAV`. Use a signed relocated
helper, isolated explicitly installed model data and #9's existing synthetic WAV.
It exercises production conversion/controller/socket, real review, CLI busy,
isolated-pasteboard Copy and cancellation/reconnect. Injected audio is not a
physical microphone or app pointer test. All unset means skip; partial setup
fails. It passed once on PR32 head 83d63f8 (macOS-build run 42540022130):
candidate, missing-copied-Frameworks counterfactual (expected workerFailed) and
restored runs, with cleanup markers. That finite hosted run is not repeated on
main. For the D27 run, first execute #9's preparation script from its separate
exact db18603 backend checkout, then explicitly install with private paths:

```sh
root="${RUNNER_TEMP:?}/hagig-issue9-native"
XDG_DATA_HOME="$root/data" XDG_CONFIG_HOME="$root/install-config" \
  "$root/Contents/Helpers/hagig" model install parakeet-tdt-0.6b-v2-int8-v1
```

The installer verifies the manifest pins, including the original tokenizer
archive, and removes the archive before publish. Independently verify all five
installed sizes/hashes and absence of retained install staging using #9's
`backend/tests/exercise_macos_candidate.sh` logic; do not run that entire script
before this test, because its exit trap deletes the model data. Never upload
models/native bytes. Supply the relocated signed app helper, `$root/data` and
the exact backend's `backend/tests/fixtures/speech.wav` to XCTest. The test creates
its own private short runtime/config, sets `[editor] mode='vim'`, inherits the
Required isolation default (no disabled override), and owns only that service.
It stops the service on success/error, removes the runtime only after successful
stop, and prints `REAL_BACKEND_CLEANUP_COMPLETE` then. A failed stop retains its
runtime for the outer cleanup gate; no cleanup marker means failure. The outer
job records each phase before invoking XCTest and requires that marker in every
invoked phase's log before disposal. On interruption, compile/setup failure or
missing marker, fail cleanup and retain the dedicated assets on the runner
(never upload them); do not delete model/app bytes beneath a possibly live pair
or kill an unverified PID. Only after the cleanup gate passes, dispose of the
dedicated model/archive/preparation and relocated copies. Upload only bounded
synthetic text evidence.

`bash clients/macos/client-proof.sh /absolute/new/evidence` runs preregistered
client-only candidate/mutant/restoration in a disposable worktree with unchanged
tests/digests and identical commands. Existing Xcode/Swift/Python only, no assets;
CI must provide the ten-minute hard timeout. Compile/setup/zero-test failures do
not count. Coverage: admission/late-result guards, PCM cap/warning, fake service
rejection, frame deadline and delayed result allowance, not every protocol claim.

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
jobs time out after ten minutes, and artifact retention is three days. The manual
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
validated server setting; the real client takes it from the server's `hello_ok`
settings during reservation, and there is no Swift TOML parsing.
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
