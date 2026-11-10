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

for experiment in admission late-result auto-stop cap warning compatibility exchange-deadline result-wait capture-failure late-admission cancel-body startup-poll upload-early runtime-fallback stale-socket wait-anchor unknown-code; do
    directory="$output/$experiment"
    mkdir "$directory"
    echo UNPROVEN > "$directory/verdict.txt"
    case "$experiment" in
        admission) test=DictationTests.testCancelDuringAdmissionNeverStartsCaptureAndLateResultNeverCopies ;;
        late-result|auto-stop) test=DictationTests.testStopCapConvergeAndCancellationWinsAgainstDelayedResult ;;
        cap|warning) test=CaptureTests.testWarningCapAndStopAreBounded ;;
        compatibility) test=SocketTests.testEveryClientFixtureExchange ;;
        exchange-deadline) test=SocketTests.testUnansweredStatusFailsAtTheFiveSecondExchangeBound ;;
        result-wait) test=SocketTests.testResultWaitOutlastsTheExchangeBound ;;
        capture-failure) test=CaptureTests.testCanonicalConversionAndFiniteValidation ;;
        late-admission) test=SocketTests.testAdmissionGrantedAfterCancelIsReleasedWithoutUploadOrCapture ;;
        cancel-body) test=SocketTests.testCancelWhileRecordingClosesTheUploadWithoutEndingTheBody ;;
        startup-poll) test=SocketTests.testHelperStartsTheServerOnceThenStatusIsRead ;;
        upload-early) test=SocketTests.testUploadOpensBeforePermissionAndStreamsBeforeStop ;;
        runtime-fallback) test=SocketTests.testFallbackIsTheDarwinTempDirNotTMPDIR ;;
        stale-socket) test=SocketTests.testLaunchHelperRunsOnlyWhenNoServerAnswers ;;
        wait-anchor) test=SocketTests.testResultWaitStartsWhenTheBodyEnds ;;
        unknown-code) test=SocketTests.testEveryClientFixtureExchange ;;
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
            '            guard presentation.requestID == id, !Task.isCancelled else { return }\n', '')
    replace('DictationController.swift',
            '            guard presentation.stage == .transcribing else { throw BackendFailure.generic }\n', '')
    replace('Presentation.swift',
            '        guard self.requestID == requestID, stage == .transcribing else { return }\n', '')
elif case == 'auto-stop':
    replace('DictationController.swift', 'case .limit: stop()', 'case .limit: break')
elif case == 'cap':
    replace('MicrophoneCapture.swift', 'maximumBytes = 19_200_000', 'maximumBytes = 19_264_000')
elif case == 'warning':
    replace('MicrophoneCapture.swift', 'sent >= 285 *', 'sent >= 286 *')
elif case == 'compatibility':
    replace('SocketRequest.swift', 'status.api_version == 1', 'status.api_version >= 1')
elif case == 'exchange-deadline':
    replace('SocketRequest.swift', 'exchangeBound: Duration = .seconds(5)', 'exchangeBound: Duration = .seconds(9)')
elif case == 'result-wait':
    replace('SocketRequest.swift', 'resultWait: Duration = .seconds(125)', 'resultWait: Duration = .seconds(5)')
elif case == 'capture-failure':
    replace('MicrophoneCapture.swift', 'if !accepted { failed = true; closed = true }',
            'if false { failed = true; closed = true }')
elif case == 'late-admission':
    replace('SocketRequest.swift', '            Self.release(socket, admitted.request_id) // Granted after the user cancelled.\n', '')
elif case == 'startup-poll':
    replace('SocketRequest.swift', '                try await Task.sleep(for: .milliseconds(50))\n',
            '                throw BackendFailure.generic\n')
elif case == 'upload-early':
    replace('SocketRequest.swift', 'upload = Task { try await Self.upload(',
            'upload = Task { try await Task.sleep(for: .seconds(4)); return try await Self.upload(')
elif case == 'runtime-fallback':
    replace('SocketRequest.swift', 'guard let temp = darwinTempDir(),',
            'guard let temp = environment["TMPDIR"] ?? darwinTempDir(),')
elif case == 'stale-socket':
    replace('SocketRequest.swift', 'retryConnectionEstablishment = false', 'retryConnectionEstablishment = true')
elif case == 'wait-anchor':
    replace('SocketRequest.swift', '            for await _ in ended { break }\n', '')
elif case == 'unknown-code':
    replace('SocketRequest.swift', 'errorStatuses[error.code]?.contains(reply.status) == true', 'true')
elif case == 'cancel-body':
    replace('SocketRequest.swift', '        feed.finish(throwing: CancellationError())\n        upload?.cancel()\n', '        feed.finish()\n')
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
                admission|late-result|cap|late-admission|cancel-body|startup-poll|runtime-fallback|stale-socket) grep -F 'XCTAssertEqual failed' "$directory/$phase.log" ;;
                auto-stop|warning|upload-early) grep -F 'XCTAssertTrue failed' "$directory/$phase.log" ;;
                wait-anchor) grep 'XCTAssertEqual failed' "$directory/$phase.log" | grep -F 'deadline_exceeded' ;;
                unknown-code) grep 'XCTAssertEqual failed' "$directory/$phase.log" | grep -F 'upload_unknown_code' ;;
                compatibility) grep 'XCTAssertEqual failed' "$directory/$phase.log" | grep -F 'status_api_version_2' ;;
                exchange-deadline) grep -F 'XCTAssertLessThan failed' "$directory/$phase.log" ;;
                result-wait) grep 'XCTAssertEqual failed' "$directory/$phase.log" | grep -F 'deadline_exceeded' ;;
                capture-failure) grep 'XCTAssertEqual failed' "$directory/$phase.log" | grep -F 'failed capture never completes its upload' ;;
            esac
        else
            [ "$result" -eq 0 ]
            grep -F 'Executed 1 test, with 0 failures' "$directory/$phase.log"
        fi
    done
    echo 'PROVEN in recorded semantic mutation mode; not base-ref causality' > "$directory/verdict.txt"
done
