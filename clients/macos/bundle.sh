#!/bin/bash
# Early layout only: synthetic UI + controlled CLI/fake worker, no inference.
set -euo pipefail

usage() {
    echo 'Usage: bash clients/macos/bundle.sh build|run'
    echo 'Build a new local Hagig.app; run also opens that bundle. Never replaces an existing bundle.'
}
if [ "$#" -eq 1 ] && [ "$1" = --help ]; then usage; exit 0; fi
if [ "$#" -ne 1 ]; then usage >&2; exit 2; fi
case "$1" in build|run) ;; *) usage >&2; exit 2 ;; esac
action=$1
mac=$(cd -- "$(dirname -- "$0")" && pwd -P)
backend=$(cd -- "$mac/../../backend" && pwd -P)
output="$mac/.build/Hagig.app"

fail() { echo "$*" >&2; exit 1; }
[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || fail 'Requires an Apple Silicon Mac (native arm64 shell).'
[ ! -L "$mac/.build" ] || fail 'Refusing a symlink .build directory.'
if [ -e "$output" ] || [ -L "$output" ]; then
    fail 'Hagig.app already exists. Quit its shell, explicitly stop its controlled service, then move the whole bundle aside before rebuilding. See clients/macos/AGENTS.md.'
fi
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode_16.4.app/Contents/Developer}
xcodebuild -version | grep -Fx 'Xcode 16.4' >/dev/null || fail 'Select Xcode 16.4 with DEVELOPER_DIR.'
mkdir -p "$mac/.build"
mkdir "$mac/.build/bundle.lock" 2>/dev/null || fail 'Another bundle build or stale bundle.lock exists; no output changed.'
stage=
cleanup() {
    if [ -n "$stage" ]; then rm -rf -- "$stage"; fi
    rmdir "$mac/.build/bundle.lock"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
stage=$(mktemp -d "$mac/.build/bundle.XXXXXX")
app="$stage/Hagig.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers"
(
    cd -- "$backend"
    # Explicit toolchain/target/output: never pick an ambient Cargo target directory.
    cargo +1.90.0 build --locked --release --bins --target aarch64-apple-darwin --target-dir "$backend/target"
)
(
    cd -- "$mac"
    swift build -c release --arch arm64 --product HagigShell
)
bin=$(cd -- "$mac" && swift build -c release --arch arm64 --show-bin-path)
cp "$bin/HagigShell" "$app/Contents/MacOS/HagigShell"
for name in hagig hagig-fake-worker; do
    cp "$backend/target/aarch64-apple-darwin/release/$name" "$app/Contents/Helpers/$name"
done
chmod 755 "$app/Contents/MacOS/HagigShell" "$app/Contents/Helpers/"*
cp "$mac/Info.plist" "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist"
# Sign nested code inside-out; never use --deep to paper over assembly mistakes.
for name in hagig hagig-fake-worker; do
    codesign --force --sign - --timestamp=none "$app/Contents/Helpers/$name"
done
codesign --force --sign - --timestamp=none "$app"
codesign --verify --deep --strict "$app"
# mkdir is exclusive: even a newly appeared output must not be overwritten/nested.
mkdir "$output"
mv "$app/Contents" "$output/Contents"
echo "Built synthetic bundle: $output"
if [ "$action" = run ]; then open "$output"; fi
