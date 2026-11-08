#!/bin/bash
# Finite automatic hosted-Mac feasibility job; not the shell acceptance gate.
set -euo pipefail
root="${RUNNER_TEMP:?}/hagig-xcui-probe"
mkdir "$root"
mkdir "$root/evidence"
{ sw_vers; uname -m; xcodebuild -version; git rev-parse HEAD; } > "$root/evidence/environment.txt"
testing=false
cleanup() {
  rm -rf "$root/result.xcresult" "$root/build.log" "$root/test.log"
  if test "$testing" = false || grep -Fxq 'HAGIG_PROBE cleanup=true' "$root/evidence/status.txt"; then
    rm -rf "$root/derived"
  else
    printf 'HAGIG_PROBE cleanup-unconfirmed=retain-dedicated-apps\n' >> "$root/evidence/status.txt"
  fi
}
trap cleanup EXIT
swift build --product HagigShell > "$root/build.log" 2>&1
shell="$(swift build --show-bin-path)/HagigShell"
project="$PWD/interaction-probe/Probe.xcodeproj"
if ! xcodebuild build-for-testing -project "$project" -scheme InteractionProbe \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$root/derived" \
    "HAGIG_PROBE_SHELL=$shell" > "$root/build.log" 2>&1; then
  printf 'HAGIG_PROBE build=false\n' | tee "$root/evidence/status.txt"
  # Compilation diagnostics only: no app or UI test has been launched.
  tail -60 "$root/build.log"
  exit 1
fi
printf 'HAGIG_PROBE build=true\n' > "$root/evidence/status.txt"
# Verify the actual generated launch configuration before starting automation.
# keepNever is Xcode's automatic-screen-capture OFF scheme option. Never export
# xcresult/raw XCTest logs, app bundles or desktop screenshots from this probe.
python3 - "$root/derived/Build/Products" "$shell" <<'PY'
import pathlib, plistlib, sys
products = pathlib.Path(sys.argv[1])
files = list(products.glob('*.xctestrun'))
assert len(files) == 1, 'one test configuration required'
def targets(value):
    if isinstance(value, dict):
        if value.get('BlueprintName') == 'InteractionProbe':
            yield value
        for item in value.values():
            yield from targets(item)
    elif isinstance(value, list):
        for item in value:
            yield from targets(item)
found = list(targets(plistlib.loads(files[0].read_bytes())))
assert len(found) == 1 and found[0].get('IsUITestBundle') is True
assert found[0].get('SystemAttachmentLifetime') == 'keepNever', 'capture must be OFF'
app = products / 'Debug/HagigShellProbe.app/Contents/MacOS/HagigShellProbe'
# The build phase copies the SwiftPM executable, without source instrumentation.
# Xcode then signs that copy; do not claim post-signing whole-file byte equality.
assert app.is_file() and pathlib.Path(sys.argv[2]).is_file()
print('HAGIG_PROBE generated-capture-policy=keepNever')
PY
codesign --verify --deep --strict "$root/derived/Build/Products/Debug/HagigShellProbe.app"
testing=true
set +e
xcodebuild test-without-building -project "$project" -scheme InteractionProbe \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$root/derived" \
  -resultBundlePath "$root/result.xcresult" -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
  -maximum-test-execution-time-allowance 60 \
  "HAGIG_PROBE_SHELL=$shell" > "$root/test.log" 2>&1
status=$?
set -e
grep '^HAGIG_PROBE ' "$root/test.log" >> "$root/evidence/status.txt" || true
printf 'HAGIG_PROBE test-exit=%s\n' "$status" >> "$root/evidence/status.txt"
cat "$root/evidence/status.txt"
test "$status" = 0
grep -Fx 'HAGIG_PROBE canary-positive=true' "$root/evidence/status.txt"
grep -Fx 'HAGIG_PROBE focus-race-receiver-unchanged=true recording-transition=true' "$root/evidence/status.txt"
grep -Fx 'HAGIG_PROBE shell-review-reached=true' "$root/evidence/status.txt"
grep -Fx 'HAGIG_PROBE cleanup=true' "$root/evidence/status.txt"
