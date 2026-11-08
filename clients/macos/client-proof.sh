#!/bin/bash
# Existing-tool native counterfactuals; run only in the approved finite CI run.
set -euo pipefail
test "$(uname -s)" = Darwin
root=$(git rev-parse --show-toplevel)
output=${1:?usage: bash clients/macos/client-proof.sh ABSOLUTE_NEW_OUTPUT_DIRECTORY}
case "$output" in /*) ;; *) exit 2 ;; esac
mkdir "$output"
scratch=
cleanup() {
    status=$?
    trap - EXIT INT TERM
    if [ -n "$scratch" ]; then
        if git -C "$root" worktree list --porcelain | grep -Fqx "worktree $scratch/tree"; then
            git -C "$root" worktree remove --force "$scratch/tree" >> "$output/cleanup.log" 2>&1 || exit 1
        fi
        rm -rf "$scratch"
    fi
    printf 'exit_status=%s\n' "$status" >> "$output/status.txt"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
git -C "$root" diff --exit-code HEAD -- clients/macos/Sources clients/macos/Tests
test -z "$(git -C "$root" ls-files --others --exclude-standard clients/macos/Sources clients/macos/Tests)"
{
    git -C "$root" rev-parse HEAD
    swift --version
    sw_vers
    shasum -a 256 "$0"
} > "$output/environment.txt" 2>&1
scratch=$(mktemp -d)
git -C "$root" worktree add --detach "$scratch/tree" HEAD > "$output/worktree.log" 2>&1
cd "$scratch/tree/clients/macos"
find Sources Tests -name '*.swift' -type f | LC_ALL=C sort | while read -r path; do
    shasum -a 256 "$path"
done > "$output/frozen.sha256"

for experiment in admission late-result auto-stop cap warning capability frame-deadline result-wait capture-failure; do
    directory="$output/$experiment"
    mkdir "$directory"
    echo UNPROVEN > "$directory/verdict.txt"
    case "$experiment" in
        admission) test=DictationTests.testCancelDuringAdmissionNeverStartsCaptureAndLateResultNeverCopies ;;
        late-result|auto-stop) test=DictationTests.testStopCapConvergeAndCancellationWinsAgainstDelayedResult ;;
        cap|warning) test=CaptureTests.testWarningCapAndStopAreBounded ;;
        capability) test=SocketTests.testFakeMalformedCapabilitiesAndDuplicateKeysAreRejected ;;
        frame-deadline) test=SocketTests.testBlockedUploadUsesFiveSecondFrameDeadline ;;
        result-wait) test=SocketTests.testFragmentedHandshakeAndDelayedUnicodeResult ;;
        capture-failure) test=CaptureTests.testCanonicalConversionAndFiniteValidation ;;
    esac
    for phase in candidate mutant restored; do
        if [ "$phase" = mutant ]; then
            python3 - "$experiment" <<'PY'
from pathlib import Path
import sys
base = Path('Sources/HagigPresentation')
def replace(file, old, new, count=1):
    path = base / file
    source = path.read_text()
    assert source.count(old) == count, (file, old, source.count(old))
    path.write_text(source.replace(old, new))
case = sys.argv[1]
if case == 'admission':
    replace('DictationController.swift',
            '                guard presentation.requestID == id, !Task.isCancelled else { request.cancel(); return }\n', '', 2)
elif case == 'late-result':
    replace('DictationController.swift',
            '                guard presentation.requestID == id, !Task.isCancelled else { return }\n', '')
    replace('Presentation.swift',
            '        guard self.requestID == requestID, stage == .transcribing else { return }\n', '')
elif case == 'auto-stop':
    replace('DictationController.swift', 'case .limit: stop()', 'case .limit: break')
elif case == 'cap':
    replace('MicrophoneCapture.swift', 'maximumBytes = 19_200_000', 'maximumBytes = 19_264_000')
elif case == 'warning':
    replace('MicrophoneCapture.swift', 'bytes.count >= 285 *', 'bytes.count >= 286 *')
elif case == 'capability':
    replace('SocketRequest.swift', 'guard worker == "inference",', 'guard worker != nil,')
elif case == 'frame-deadline':
    replace('SocketRequest.swift', 'deadline: min(uploadDeadline, .now.advanced(by: .seconds(5))))',
            'deadline: uploadDeadline)', 2)
elif case == 'result-wait':
    replace('SocketRequest.swift', 'deadline: .now.advanced(by: .seconds(125)))',
            'deadline: .now.advanced(by: .seconds(5)))')
elif case == 'capture-failure':
    replace('MicrophoneCapture.swift', 'if !accepted { bytes.removeAll(); closed = true }',
            'if false { bytes.removeAll(); closed = true }')
else:
    raise AssertionError(case)
PY
            git diff --binary -- Sources > "$directory/mutation.patch"
            test -s "$directory/mutation.patch"
            git diff --exit-code -- Tests # Frozen artifact, never mutate tests.
        elif [ "$phase" = restored ]; then
            git apply --reverse "$directory/mutation.patch"
        fi
        if [ "$phase" != mutant ]; then
            shasum -a 256 -c "$output/frozen.sha256" > "$directory/$phase.sha256.log"
            git diff --exit-code
        fi
        printf 'swift test --scratch-path %q --filter %q\n' "$scratch/build" "$test" > "$directory/$phase.command"
        result=0
        swift test --scratch-path "$scratch/build" --filter "$test" > "$directory/$phase.log" 2>&1 || result=$?
        printf '%s\n' "$result" > "$directory/$phase.exit"
        cat "$directory/$phase.log"
        grep -Eq 'Executed 1 test, with [0-9]+ failures?' "$directory/$phase.log"
        if [ "$phase" = mutant ]; then
            [ "$result" -eq 1 ]
            case "$experiment" in
                admission|late-result|cap|frame-deadline) grep -F 'XCTAssertEqual failed' "$directory/$phase.log" ;;
                auto-stop) grep -F 'Timed out waiting for controlled boundary' "$directory/$phase.log" ;;
                warning) grep -F 'XCTAssertTrue failed' "$directory/$phase.log" ;;
                capability) grep -F 'Incompatible peer accepted' "$directory/$phase.log" ;;
                result-wait) grep -F 'failed: caught error: "BackendFailure(issue: HagigPresentation.DemoIssue.deadlineExceeded)"' "$directory/$phase.log" ;;
                capture-failure) grep 'XCTAssertTrue failed' "$directory/$phase.log" | grep -F 'failed capture discards prior PCM before Stop' ;;
            esac
        else
            [ "$result" -eq 0 ]
            grep -F 'Executed 1 test, with 0 failures' "$directory/$phase.log"
        fi
    done
    echo 'PROVEN in recorded semantic mutation mode; not base-ref causality' > "$directory/verdict.txt"
done
