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
This is a SwiftPM executable, not a signed, relocatable `.app` distribution.

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
