#!/bin/bash
# Local Hagig.app: HagigShell plus the uv-managed Python interpreter and the
# locked backend environment (TDD section 4). `uv sync` below is the only network
# step. Launching the result never resolves, syncs or downloads anything.
set -euo pipefail

usage() {
    echo 'Usage: bash clients/macos/bundle.sh build|run'
    echo 'Build a new local Hagig.app; run also opens it. Never replaces an existing bundle.'
    echo 'Needs Xcode 16.4 and uv. Installs no model; model install is a separate explicit step.'
}
if [ "$#" -eq 1 ] && [ "$1" = --help ]; then usage; exit 0; fi
if [ "$#" -ne 1 ]; then usage >&2; exit 2; fi
case "$1" in build|run) ;; *) usage >&2; exit 2 ;; esac
action=$1
mac=$(cd -- "$(dirname -- "$0")" && pwd -P)
root=$(cd -- "$mac/../.." && pwd -P)
output="$mac/.build/Hagig.app"

# The one place that chooses the bundled environment: the frozen lock, runtime
# dependencies plus both inference engines (#47's extras; mlx-whisper is empty
# off Apple Silicon), a uv-managed (python-build-standalone) interpreter, and the
# project installed as a wheel rather than an editable link to this checkout.
# The variable, not --managed-python, which uv refuses beside an inherited one.
sync_backend() {
    (cd -- "$root/backend" && UV_PROJECT_ENVIRONMENT="$1" UV_PYTHON_PREFERENCE=only-managed \
        uv sync --frozen --no-dev --no-editable --extra qwen3-asr --extra mlx-whisper)
}

fail() { echo "$*" >&2; exit 1; }
[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || fail 'Requires an Apple Silicon Mac (native arm64 shell).'
command -v uv >/dev/null || fail 'Install uv; it is needed to build, not to run, the bundle.'
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
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
(
    cd -- "$mac"
    swift build -c release --arch arm64 --product HagigShell
)
bin=$(cd -- "$mac" && swift build -c release --arch arm64 --show-bin-path)
cp "$bin/HagigShell" "$app/Contents/MacOS/HagigShell"
# SwiftPM's shell needs system libraries only.
install_name_tool -delete_rpath '@loader_path' "$app/Contents/MacOS/HagigShell"

# uv environments are not relocatable: a venv records its interpreter by absolute
# path. Instead, copy the managed interpreter itself (python-build-standalone finds
# its prefix from its own location) and install the environment's packages into
# that interpreter's site-packages. `python -I`, which every Hagig process uses,
# then sees exactly those packages from wherever the bundle is moved.
env_dir="$stage/env"
sync_backend "$env_dir"
version=$("$env_dir/bin/python" -I -c 'import sys; print("%d.%d" % sys.version_info[:2])')
base=$("$env_dir/bin/python" -I -c 'import os, sys; print(os.path.realpath(sys.base_prefix))')
# only-managed alone is not enough: an explicit UV_PYTHON path bypasses it.
managed=$(cd -P -- "$(uv python dir)" && pwd -P)
case "$base" in "$managed"/*) ;; *) fail 'The environment does not use a uv-managed interpreter.' ;; esac
python="$app/Contents/Resources/python"
cp -R "$base" "$python"
# Runtime only: no headers, docs, build configuration, pip or its bundled wheels,
# Tcl/Tk GUI code and libraries, or scripts with build-host shebangs.
stdlib="$python/lib/python$version"
rm -rf "$python/include" "$python/share" "$python/lib/pkgconfig" "$stdlib/site-packages" \
    "$stdlib"/config-"$version"-* "$stdlib/ensurepip" "$stdlib/idlelib" "$stdlib/tkinter" \
    "$stdlib/turtledemo" "$stdlib"/lib-dynload/_tkinter.* \
    "$python"/lib/tcl* "$python"/lib/tk* "$python"/lib/itcl* "$python"/lib/thread* \
    "$python"/lib/libtcl* "$python"/lib/libtk*
find "$python/bin" -mindepth 1 ! -name "python$version" -exec rm -f {} +
site="$python/lib/python$version/site-packages"
cp -R "$env_dir/lib/python$version/site-packages" "$site"
# Not uv's venv shim, install-source records that name this checkout, or
# setuptools' build-time `import distutils` redirect (torch requires setuptools).
rm -f "$site/_virtualenv.py" "$site/_virtualenv.pth" "$site"/__pycache__/_virtualenv.* \
    "$site"/*.dist-info/direct_url.json "$site/distutils-precedence.pth"
# Even under -I, site.py processes .pth files and imports sitecustomize and
# usercustomize: none may run unreviewed code or extend sys.path.
if [ -n "$(find "$python/lib" \( -name '*.pth' -o -name sitecustomize.py -o -name usercustomize.py \) -print -quit)" ]; then
    fail 'A .pth, sitecustomize or usercustomize file would run at startup; review it before bundling.'
fi
interpreter="$python/bin/python$version"
# Precompile everything so no process writes __pycache__ into the signed bundle.
# Unchecked hashes stay valid however the copy changes file times. Strip the
# staging prefix from recorded source names (import fixes them up on load), so
# no file names the build path.
"$interpreter" -I -m compileall -q -f -j 0 --invalidation-mode unchecked-hash \
    -s "$python" -p /hagig-bundle "$python/lib/python$version"
"$interpreter" -I -c 'import hagig.cli, hagig.server, hagig.worker
from importlib.resources import files
from hagig.launcher import SEATBELT_PROFILE
assert SEATBELT_PROFILE.is_file(), "Seatbelt profile missing from the environment"
manifests = {p.name for p in (files("hagig") / "manifests").iterdir() if p.name.endswith(".json")}
assert manifests == {"qwen3-asr-0.6b.json", "qwen3-asr-1.7b.json", "whisper-large-v3-turbo.json"}, manifests'

helper="$app/Contents/Helpers/hagig"
cat > "$helper" <<'HELPER'
#!/bin/sh
# The Hagig CLI paired with this app, generated by clients/macos/bundle.sh. Runs
# the bundled interpreter relative to this file; never uv, PATH or a checkout.
unset CDPATH
case $0 in */*) helpers=${0%/*} ;; *) helpers=. ;; esac
contents=$(cd -P -- "$helpers/.." && pwd -P) || exit 1
export UV_OFFLINE=1 UV_PYTHON_DOWNLOADS=never
exec "$contents/Resources/python/bin/python@VERSION@" -I -B -c 'from hagig.cli import app; app(prog_name="hagig")' "$@"
HELPER
template=$(< "$helper")
printf '%s\n' "${template//@VERSION@/$version}" > "$helper"
chmod 755 "$app/Contents/MacOS/HagigShell" "$app/Contents/Helpers/hagig"
# The Python package carries no license text of its own.
cp "$root/LICENSE" "$app/Contents/Resources/LICENSE"
cp "$mac/Info.plist" "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist"

# Ad-hoc sign nested code inside-out (every Mach-O library and executable, then
# the helper and shell, then the app); never use --deep to paper over mistakes.
machos=()
while IFS= read -r -d '' file; do
    case "$(file -b "$file")" in Mach-O*) machos+=("$file") ;; esac
done < <(find "$python" -type f \( -name '*.so' -o -name '*.dylib' -o -perm -u+x \) -print0)
[ "${#machos[@]}" -gt 0 ] || fail 'No interpreter code found to sign.'
# Some wheels keep their build machine's absolute loader search paths (scipy:
# /opt/homebrew/Cellar/gcc@13/...). They resolve nothing the bundle needs, and on
# a Mac with Homebrew they name user-writable directories a library could be
# planted in. Keep only bundle-relative and sealed system-volume search paths.
for file in "${machos[@]}"; do
    while read -r rpath; do
        case "$rpath" in
            @loader_path*|@executable_path*|/usr/lib|/usr/lib/*|/System/Library/*) ;;
            *) echo "Removing build-host loader search path $rpath from ${file#"$python"/}"
               install_name_tool -delete_rpath "$rpath" "$file" ;;
        esac
    done < <(otool -l -arch arm64 "$file" | awk '/cmd LC_RPATH/ { path = 1; next } path && $1 == "path" { print $2; path = 0 }')
done
codesign --force --sign - --timestamp=none "${machos[@]}"
codesign --force --sign - --timestamp=none "$app/Contents/Helpers/hagig" "$app/Contents/MacOS/HagigShell"
codesign --force --sign - --timestamp=none "$app"
codesign --verify --deep --strict "$app"
# mkdir is exclusive: even a newly appeared output must not be overwritten/nested.
mkdir "$output"
mv "$app/Contents" "$output/Contents"
echo "Built experimental bundle (not adoption/physical-Mac acceptance): $output"
if [ "$action" = run ]; then open "$output"; fi
