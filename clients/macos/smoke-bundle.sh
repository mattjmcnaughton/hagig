#!/bin/bash
# Native macOS smoke only. Never connects to or stops the user's runtime service.
set -euo pipefail
[ "$#" -eq 0 ] || { echo 'Usage: bash clients/macos/smoke-bundle.sh' >&2; exit 2; }
[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || exit 1
mac=$(cd -- "$(dirname -- "$0")" && pwd -P)
source_app="$mac/.build/Hagig.app"
[ -d "$source_app" ] || { echo 'Build the bundle first.' >&2; exit 1; }
scratch=$(mktemp -d /tmp/hagig-bundle.XXXXXX)
shell_pid=
cli=
cleanup() {
    status=$?
    trap - EXIT
    if [ -n "$shell_pid" ]; then
        kill "$shell_pid" 2>/dev/null || true
        wait "$shell_pid" 2>/dev/null || true
    fi
    # Only this disposable runtime is in scope. Retain bytes if stop fails.
    if [ -n "$cli" ] && ! "$cli" stop; then
        echo "Cleanup failed; retained private smoke directory: $scratch" >&2
        exit 1
    fi
    rm -rf -- "$scratch"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -m 700 "$scratch/runtime" "$scratch/relocated app"
export XDG_RUNTIME_DIR="$scratch/runtime"
cp -R "$source_app" "$scratch/relocated app/Hagig.app"
app="$scratch/relocated app/Hagig.app"
codesign --verify --deep --strict "$app"
plutil -lint "$app/Contents/Info.plist"
for binary in "$app/Contents/MacOS/HagigShell" "$app/Contents/Helpers/"*; do
    file "$binary" | grep 'arm64'
    otool -L "$binary"
    # Permit only OS/Swift system libraries and frameworks, not checkout dylibs.
    otool -L "$binary" | tail -n +2 | while read -r dependency; do
        case "$dependency" in
            /usr/lib/*|/System/Library/*|@rpath/libswift*.dylib\ *) ;;
            *) echo 'Non-system loader dependency needs explicit bundle integration.' >&2; exit 1 ;;
        esac
    done
    otool -l "$binary" | awk '/cmd LC_RPATH/ { path = 1; next } path && $1 == "path" { print $2; path = 0 }' |
        while read -r rpath; do
            case "$rpath" in
                /usr/lib/swift) ;;
                *) echo "Non-system loader search path needs explicit bundle integration: $rpath" >&2; exit 1 ;;
            esac
        done
done
cli="$app/Contents/Helpers/hagig"
[ "$("$cli" status)" = stopped ]
"$cli" fake-request --fake-worker > "$scratch/result"
[ "$(wc -c < "$scratch/result" | tr -d ' ')" = 1 ]
[ -z "$(cat "$scratch/result")" ]
"$cli" status
"$cli" stop
[ "$("$cli" status)" = stopped ]
# Launch the relocated real shell executable, observe liveness, stop only our PID.
# This is not LaunchServices/menu/keyboard/TCC/physical-Mac acceptance.
"$app/Contents/MacOS/HagigShell" &
shell_pid=$!
sleep 2
kill -0 "$shell_pid"
echo 'Relocated synthetic shell remained alive; controlled sibling worker completed with Required default.'
