#!/bin/bash
# Local experimental bundle from #9's explicitly prepared native Contents.
set -euo pipefail

usage() {
    echo 'Usage: bash clients/macos/bundle.sh build|run /absolute/prepared/Contents'
    echo 'Build a new local Hagig.app; run also opens that bundle. Never replaces an existing bundle.'
    echo 'Prepare the exact backend/native candidate separately. This command never downloads assets or installs models.'
}
if [ "$#" -eq 1 ] && [ "$1" = --help ]; then usage; exit 0; fi
if [ "$#" -ne 2 ]; then usage >&2; exit 2; fi
case "$1" in build|run) ;; *) usage >&2; exit 2 ;; esac
case "$2" in /*) ;; *) usage >&2; exit 2 ;; esac
action=$1
native=$2
mac=$(cd -- "$(dirname -- "$0")" && pwd -P)
output="$mac/.build/Hagig.app"

fail() { echo "$*" >&2; exit 1; }
[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || fail 'Requires an Apple Silicon Mac (native arm64 shell).'
for member in Helpers/hagig Helpers/hagig-worker Helpers/hagig-inference-worker \
              Frameworks/libsherpa-onnx-c-api.dylib Frameworks/libonnxruntime.dylib; do
    [ -f "$native/$member" ] && [ ! -L "$native/$member" ] || fail 'Prepared native Contents is incomplete or contains a symlink member.'
done
[ ! -L "$mac/.build" ] || fail 'Refusing a symlink .build directory.'
if [ -e "$output" ] || [ -L "$output" ]; then
    fail 'Hagig.app already exists. Quit its shell, explicitly stop its shared service, then move the whole bundle aside before rebuilding. See clients/macos/AGENTS.md.'
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
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Frameworks"
(
    cd -- "$mac"
    swift build -c release --arch arm64 --product HagigShell
)
bin=$(cd -- "$mac" && swift build -c release --arch arm64 --show-bin-path)
cp "$bin/HagigShell" "$app/Contents/MacOS/HagigShell"
# SwiftPM's shell needs system libraries only. The separate native helper keeps
# #9's tested Frameworks rpath/IDs; never rewrite its loader commands here.
install_name_tool -delete_rpath '@loader_path' "$app/Contents/MacOS/HagigShell"
for name in hagig hagig-worker hagig-inference-worker; do
    cp "$native/Helpers/$name" "$app/Contents/Helpers/$name"
done
for name in libonnxruntime.dylib libsherpa-onnx-c-api.dylib; do
    cp "$native/Frameworks/$name" "$app/Contents/Frameworks/$name"
done
chmod 755 "$app/Contents/MacOS/HagigShell" "$app/Contents/Helpers/"*
cp "$mac/Info.plist" "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist"
# Sign nested code inside-out; never use --deep to paper over assembly mistakes.
for name in libonnxruntime.dylib libsherpa-onnx-c-api.dylib; do
    codesign --force --sign - --timestamp=none "$app/Contents/Frameworks/$name"
done
for name in hagig hagig-worker hagig-inference-worker; do
    codesign --force --sign - --timestamp=none "$app/Contents/Helpers/$name"
done
codesign --force --sign - --timestamp=none "$app"
codesign --verify --deep --strict "$app"
# mkdir is exclusive: even a newly appeared output must not be overwritten/nested.
mkdir "$output"
mv "$app/Contents" "$output/Contents"
echo "Built experimental bundle (not adoption/physical-Mac acceptance): $output"
if [ "$action" = run ]; then open "$output"; fi
