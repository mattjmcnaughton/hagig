#!/bin/bash
# Native synthetic shell interaction; no microphone/backend acceptance claim.
set -euo pipefail
umask 077
root="${RUNNER_TEMP:?}/hagig-xcui-probe"
mkdir "$root"
mkdir "$root/evidence"
mkdir "$root/bridge"
{ sw_vers; uname -m; xcodebuild -version; git rev-parse HEAD; } > "$root/evidence/environment.txt"
testing=false
cleanup() {
  rm -rf "$root/result.xcresult" "$root/build.log" "$root/test.log" "$root/capture.log"
  if test "$testing" = false || { grep -Fxq 'HAGIG_PROBE cleanup=true' "$root/evidence/status.txt" &&
      grep -Fxq 'HAGIG_PROBE recorder-cleanup=true' "$root/evidence/status.txt"; }; then
    rm -rf "$root/derived" "$root/bridge" "$root/recorder"
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
swiftc -swift-version 5 -parse-as-library shell-interaction.swift -o "$root/recorder"
# Verify the actual generated launch configuration before starting automation.
# keepNever is Xcode's automatic-screen-capture OFF scheme option. Never export
# xcresult/raw XCTest logs, app bundles or desktop screenshots from this probe.
python3 - "$root/derived/Build/Products" "$shell" "$root/bridge" <<'PY'
import pathlib, plistlib, subprocess, sys, uuid
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
configuration = plistlib.loads(files[0].read_bytes())
found = list(targets(configuration))
assert len(found) == 1 and found[0].get('IsUITestBundle') is True
assert found[0].get('SystemAttachmentLifetime') == 'keepNever', 'capture must be OFF'
# Only the existing exact-application ScreenCaptureKit recorder can export media.
# Use this SAME verified configuration, not a regenerated project configuration.
name = 'com.mattjmcnaughton.hagig.synthetic-recording-' + str(uuid.uuid4())
found[0].setdefault('EnvironmentVariables', {})['HAGIG_PROBE_BRIDGE'] = name
pathlib.Path(sys.argv[3], 'control-name').write_text(name)
files[0].write_bytes(plistlib.dumps(configuration))
app = products / 'Debug/HagigShellProbe.app/Contents/MacOS/HagigShellProbe'
# The build phase copies the SwiftPM executable, without source instrumentation.
# Xcode then signs that copy; do not claim post-signing whole-file byte equality.
assert app.is_file() and pathlib.Path(sys.argv[2]).is_file()
print('HAGIG_PROBE generated-capture-policy=keepNever')
runner, = (products / 'Debug').glob('*-Runner.app')
metadata = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(runner)],
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=True).stdout
entitlements = plistlib.loads(metadata) if metadata else {}
print('HAGIG_PROBE runner-app-sandbox=' + str(entitlements.get('com.apple.security.app-sandbox') is True).lower())
PY
codesign --verify --deep --strict "$root/derived/Build/Products/Debug/HagigShellProbe.app"
testing=true
set +e
python3 - "$root" <<'PY'
import pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1])
configuration, = (root / 'derived/Build/Products').glob('*.xctestrun')
app = root / 'derived/Build/Products/Debug/HagigShellProbe.app'
command = ['xcodebuild', 'test-without-building', '-xctestrun', str(configuration),
           '-destination', 'platform=macOS,arch=arm64', '-resultBundlePath', str(root / 'result.xcresult'),
           '-parallel-testing-enabled', 'NO', '-test-timeouts-enabled', 'YES',
           '-default-test-execution-time-allowance', '120', '-maximum-test-execution-time-allowance', '120']
with (root / 'capture.log').open('w') as capture_log, (root / 'test.log').open('w') as test_log:
    name = (root / 'bridge/control-name').read_text()
    recorder = subprocess.Popen([str(root / 'recorder'), str(app), str(root / 'bridge'), name],
                                stdout=capture_log, stderr=subprocess.STDOUT)
    try:
        test_status = subprocess.run(command, stdout=test_log, stderr=subprocess.STDOUT, timeout=150).returncode
    except subprocess.TimeoutExpired:
        test_status = 124
    finally:
        try:
            recorder_status = recorder.wait(timeout=8)
        except subprocess.TimeoutExpired:
            # Only this retained child. Failed cleanup never exports a movie.
            recorder.terminate()
            try:
                recorder.wait(timeout=5)
            except subprocess.TimeoutExpired:
                recorder.kill()
                recorder.wait(timeout=3)
            recorder_status = 124
print('HAGIG_PROBE native-test-exit=' + str(test_status))
print('HAGIG_PROBE recorder-exit=' + str(recorder_status))
sys.exit(0 if test_status == 0 and recorder_status == 0 else 1)
PY
status=$?
set -e
grep '^HAGIG_PROBE ' "$root/test.log" >> "$root/evidence/status.txt" || true
grep '^HAGIG_PROBE ' "$root/capture.log" >> "$root/evidence/status.txt" || true
python3 - "$root/test.log" >> "$root/evidence/status.txt" <<'PY'
import pathlib, re, sys
# Preserve locations, never XCTest assertion values or UI/content diagnostics.
log = pathlib.Path(sys.argv[1]).read_text(errors='replace')
for line in sorted(set(re.findall(r'InteractionProbe\.swift:(\d+):', log))):
    print('HAGIG_PROBE failure-line=' + line)
# Fixed classifications only. Raw XCTest diagnostics can contain UI contents.
for category, phrase in {
    'synthesis': 'failed to synthesize',
    'snapshot': 'failed to get matching snapshot',
    'no-match': 'no matches found',
    'not-hittable': 'not hittable',
    'timeout': 'timed out',
    'assertion': 'XCTAssert',
    'keyboard': 'keyboard event',
    'pasteboard': 'pasteboard',
    'permission': 'not authorized',
    'not-running': 'application is not running',
    'main-thread': 'main thread',
}.items():
    if phrase.lower() in log.lower():
        print('HAGIG_PROBE diagnostic-category=' + category)
PY
grep -E '^PASS recorder\.|^cleanup temporary-recording-removed=' "$root/capture.log" >> "$root/evidence/status.txt" || true
printf 'HAGIG_PROBE test-exit=%s\n' "$status" >> "$root/evidence/status.txt"
cat "$root/evidence/status.txt"
test "$status" = 0
grep -Fx 'HAGIG_PROBE canary-positive=true' "$root/evidence/status.txt"
grep -Fx 'HAGIG_PROBE focus-race-receiver-unchanged=true recording-transition=true' "$root/evidence/status.txt"
grep -Fx 'HAGIG_PROBE focus-race-key-receiver-unchanged=true' "$root/evidence/status.txt"
grep -Fx 'HAGIG_PROBE shell-review-reached=true' "$root/evidence/status.txt"
grep -Fx 'HAGIG_PROBE standard-edit-select-copy-cut-undo-escape-pointer-copy=true' "$root/evidence/status.txt"
grep -Fx 'HAGIG_PROBE standard-pointer-dismiss-reopen=true' "$root/evidence/status.txt"
grep -Fx 'HAGIG_PROBE vim-insert-escape-visual-delete-undo-register=true' "$root/evidence/status.txt"
grep -Fx 'HAGIG_PROBE vim-native-paste-normal-cursor-keyboard-copy-dismiss=true' "$root/evidence/status.txt"
grep -Fx 'HAGIG_PROBE focus-standard-owned-text-area=true' "$root/evidence/status.txt"
grep -Fx 'HAGIG_PROBE focus-vim-owned-text-area=true' "$root/evidence/status.txt"
grep -Fx 'HAGIG_PROBE active-escape-cancel-error-recovery-no-copy=true' "$root/evidence/status.txt"
grep -Fx 'HAGIG_PROBE scenario-complete=true' "$root/evidence/status.txt"
grep -Fx 'HAGIG_PROBE cleanup=true' "$root/evidence/status.txt"
grep -Fx 'HAGIG_PROBE recorder-cleanup=true' "$root/evidence/status.txt"
mv "$root/bridge/candidate.mov" "$root/evidence/interaction.mov"
printf 'HAGIG_PROBE movie-published=true\n' >> "$root/evidence/status.txt"
test -s "$root/evidence/interaction.mov"
