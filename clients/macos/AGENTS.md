# Native shell and screenshot workflow

Read the root guidance, constitution, MVP PRD and TDD. The reviewed UI source is
`docs/product/prototypes/`; its browser checks do not validate this native client.
This is a synthetic shell, not an implemented dictation pipeline or installed alpha.

## Boundaries

- `HagigPresentation/Presentation.swift`: in-memory presentation/actions, request
  identity guard for simulated late results, and synthetic fixtures. This is not
  authoritative server state, a Swift inference backend, or an IPC implementation.
- `HagigPresentation/HagigView.swift`: reusable real SwiftUI surface. The shell and
  capture executable must use this same view; never duplicate screenshot UI.
- `HagigShell`: AppKit status item/popover and explicit current-host-only clipboard
  writes. Only Copy writes; no automatic paste, key injection, permission requests,
  microphone, model downloads, or server launch. Demo error selection is shell-only.
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

Click the menu-bar microphone to open the demo; use Simulate recording → Simulate
release → Simulate result → explicit Copy or Dismiss. Escape cancels active work.
Preview error and Quit live below the shared surface. No global shortcut exists.
`swift run HagigShell` is the unbundled SwiftPM demo, not the bundle launch path.

## Early local bundle layout (#23 checkpoint, not dictation)

From the clone root on an Apple Silicon Mac, native arm64 shell, Xcode 16.4 and
the repository's Rust 1.90.0 toolchain installed via rustup and on PATH:

```sh
bash clients/macos/bundle.sh run    # build a NEW bundle, then terminal-launch via open
# Or build only, for iteration/CI:
bash clients/macos/bundle.sh build
# Launch an already built bundle without rebuilding:
open clients/macos/.build/Hagig.app
```

These are alternative build commands, not consecutive commands: an existing
output is always refused (including symlinks). No Homebrew, release download,
`/Applications` copy, certificates or notarization credentials are required.
The default Xcode path is `/Applications/Xcode_16.4.app/Contents/Developer`;
`DEVELOPER_DIR` may select another installation of exactly Xcode 16.4. Cargo uses
`+1.90.0`, `--locked` and an explicit native target; building may fetch locked
crate sources/toolchains through ordinary Cargo/rustup, not model/native assets.
Swift builds only the existing HagigShell product. Build output is ignored under
`clients/macos/.build/` and `backend/target/`.

Layout (all paths relative to the bundle):

```text
Hagig.app/Contents/Info.plist
Hagig.app/Contents/MacOS/HagigShell
Hagig.app/Contents/Helpers/hagig
Hagig.app/Contents/Helpers/hagig-fake-worker
```

Bundle identity is `com.mattjmcnaughton.hagig`. The existing CLI reexecutes itself
as the controlled server and finds `hagig-fake-worker` beside its own executable,
not on PATH. There is no separate real worker, inference library or model to
bundle yet. The shell does **not** start/connect to this server. To exercise the
controlled backend explicitly, use (from clone root):

```sh
clients/macos/.build/Hagig.app/Contents/Helpers/hagig status
clients/macos/.build/Hagig.app/Contents/Helpers/hagig fake-request --fake-worker
clients/macos/.build/Hagig.app/Contents/Helpers/hagig stop
```

Default Required isolation is retained; failure never retries Disabled. This is
empty-result fake lifecycle work, not WAV transcription. `hagig transcribe`,
model installation, real Record/Stop/edit/Copy and shared app/server busy policy
are NOT implemented by packaging. No assets are downloaded or repaired on launch.

Before rebuilding/replacing any paired bundle: Quit its synthetic shell, coordinate
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

Nested helpers and the outer app are ad-hoc signed inside-out, then verified.
Ad-hoc signing is not Developer ID, notarization, Gatekeeper approval, TCC grant,
permission stability across rebuilds, or worker-isolation proof. Diagnose launch
or signing failures; do not disable Gatekeeper. Info.plist contains a microphone
usage description for future intentional recording, **not a request**. This
shell requests no Microphone, Accessibility or Input Monitoring permission.
Stable identity alone does not establish TCC continuity; denial/grant/rebuild
testing waits for real capture integration. Signing identity/loader paths for
future adopted native assets must be integrated and verified separately.

Checks (from clone root):

```sh
python3 clients/macos/test_bundle.py   # stdlib disposable PATH stand-ins, NOT native evidence
bash clients/macos/smoke-bundle.sh    # macOS only, after build-only above
```

The native smoke copies the bundle away from the checkout into a disposable path
with spaces, checks arm64/system-only loader paths and signatures, runs the actual
controlled CLI/worker with Required default using a private temporary runtime,
then launches the relocated shell executable briefly and terminates only that
owned PID. Its cleanup stops only its isolated service and preserves scratch on
stop failure. It does not touch the user's live runtime. It is not a terminal
LaunchServices interaction test or runtime-free physical-Mac installation proof.
Normal `macos-build.yml` includes this smoke; exact-head success and inspection
remain required. No native bundle check has been executed in the Linux orb.
Full #23 acceptance remains blocked on real integration (#9/#21/#22, adopted
inference), macOS launch/relocation/signing/TCC and owner physical-Mac checks.

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
