#!/bin/bash
# Native semantic evidence only. CI supplies the five-minute hard deadline.
set -euo pipefail

root=$(git rev-parse --show-toplevel)
output=${1:?usage: bash semantic-proof.sh ABSOLUTE_NEW_OUTPUT_DIRECTORY}
case "$output" in /*) ;; *) echo 'Output must be absolute' >&2; exit 2 ;; esac
mkdir "$output" # Refuse to overwrite or mix evidence from earlier runs.
scratch=''
cleanup() {
    status=$?
    trap - EXIT INT TERM
    if [ -n "$scratch" ]; then
        if ! git -C "$root" worktree remove --force "$scratch/tree" >> "$output/cleanup.log" 2>&1; then
            # A failed add may never have registered a worktree.
            if git -C "$root" worktree list --porcelain | grep -Fqx "worktree $scratch/tree"; then
                echo "Cleanup failed: $scratch" >> "$output/cleanup.log"
                exit 1
            fi
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
{
    git -C "$root" rev-parse HEAD
    git -C "$root" rev-parse HEAD:clients/macos
    swift --version
    shasum -a 256 "$0"
} > "$output/environment.txt" 2>&1
scratch=$(mktemp -d)
git -C "$root" worktree add --detach "$scratch/tree" HEAD > "$output/worktree.log" 2>&1
package="$scratch/tree/clients/macos"
artifact=Tests/HagigPresentationTests/EditorTests.swift
editor=Sources/HagigPresentation/ReviewEditor.swift
presentation=Sources/HagigPresentation/Presentation.swift
cd "$package"
shasum -a 256 "$artifact" "$editor" "$presentation" > "$output/frozen.sha256"

verify_restored() {
    shasum -a 256 -c "$output/frozen.sha256"
    git diff --exit-code
}

run_test() {
    phase=$1
    # Exactly the same command and environment for all three phases.
    printf 'swift test --scratch-path %q --filter %q\n' "$scratch/build" "EditorTests.$test" > "$directory/$phase.command"
    result=0
    swift test --scratch-path "$scratch/build" --filter "EditorTests.$test" > "$directory/$phase.log" 2>&1 || result=$?
    printf '%s\n' "$result" > "$directory/$phase.exit"
    cat "$directory/$phase.log"
    # Zero tests, build failures and crashes cannot satisfy either side.
    grep -Eq 'Executed 1 test, with [0-9]+ failures?' "$directory/$phase.log"
    if [ "$phase" = mutant ]; then
        [ "$result" -eq 1 ] # Swift test failure, not a signal/crash exit.
        grep -F "Test Case '-[HagigPresentationTests.EditorTests $test]' failed" "$directory/$phase.log"
        if [ "$experiment" = dw-newline ]; then
            # This fixed LF fixture puts the assertion message on the next line.
            grep -A 1 'XCTAssertEqual failed:' "$directory/$phase.log" | grep -F "$assertion"
        elif [ "$experiment" = crlf-register ]; then
            grep 'XCTAssertTrue failed' "$directory/$phase.log" | grep -F "$assertion"
        else
            grep 'XCTAssertEqual failed' "$directory/$phase.log" | grep -F "$assertion" | grep -F "$detail"
        fi
    else
        [ "$result" -eq 0 ]
        grep -F 'Executed 1 test, with 0 failures' "$directory/$phase.log"
    fi
}

for experiment in editor-copy presentation-copy immediate-discard dd-cursor dw-newline crlf-register paste-cursor paste-visual; do
    directory="$output/$experiment"
    mkdir "$directory"
    echo 'UNPROVEN: experiment has not completed candidate/mutant/restoration' > "$directory/verdict.txt"
    test=testSharedSurfaceEditedCopyAndImmediateDismissDiscard
    assertion='mutation synthetic stale'
    detail='edited'
    case "$experiment" in
        editor-copy)
            source=$editor
            replacement='s/^        _ = write(string)$/        _ = write("mutation synthetic stale")/'
            ;;
        presentation-copy)
            test=testEditedCopyFeedbackAndSessionInvalidation
            source=$presentation
            replacement='s/^        copied = write(transcript)$/        copied = write("mutation synthetic stale")/'
            ;;
        immediate-discard)
            source=$presentation
            replacement='/^        discardEditor?()$/d'
            assertion='edited 😀'
            ;;
        dd-cursor)
            source=$editor
            test=testNormalCursorAtDeletionAndEmptyLineBoundaries
            replacement='s/select(min(start, characters.count))/select(min(lineStart(p), characters.count))/'
            assertion='5ldd'
            detail='XCTAssertEqual failed'
            ;;
        dw-newline)
            source=$editor
            test=testDeletesRegisterPasteAndUndoRedo
            replacement='s/end = min(end, lineEnd(start))/end = min(end, characters.count)/'
            assertion='"one\ntwo": dw'
            detail='XCTAssertEqual failed'
            ;;
        crlf-register)
            source=$editor
            test=testDeletesRegisterPasteAndUndoRedo
            replacement='s/register.last?.isNewline != true/!register.hasSuffix("\\n")/'
            assertion='linewise register preserves CRLF'
            ;;
        paste-cursor)
            source=$editor
            test=testNativePastedTextPreservesEditorCursorMode
            replacement='/^        if accepted { normalCursor() }$/d'
            assertion='native paste cursor follows editor mode'
            detail='XCTAssertEqual failed'
            ;;
        paste-visual)
            source=$editor
            test=testNativePastedTextPreservesEditorCursorMode
            replacement='s/^        if accepted, mode == .visual || mode == .visualLine {$/        if accepted, false {/'
            assertion='native paste exits replaced Visual selection'
            detail='XCTAssertEqual failed'
            ;;
    esac
    verify_restored > "$directory/before.sha256.log"
    run_test candidate
    sed "$replacement" "$source" > "$scratch/mutated.swift"
    mv "$scratch/mutated.swift" "$source"
    git diff --binary -- "$source" > "$directory/mutation.patch"
    test -s "$directory/mutation.patch"
    shasum -a 256 "$artifact" "$editor" "$presentation" > "$directory/mutant.sha256"
    # Test bytes must remain frozen even while production semantics differ.
    cmp <(head -n 1 "$directory/mutant.sha256") <(head -n 1 "$output/frozen.sha256")
    run_test mutant
    git -C "$scratch/tree" apply --reverse "$directory/mutation.patch"
    verify_restored > "$directory/restored.sha256.log"
    run_test restored
    printf '%s: PROVEN (mutation mode; see identical commands, logs and patch)\n' "$experiment" > "$directory/verdict.txt"
done
verify_restored > "$output/final.sha256.log"
