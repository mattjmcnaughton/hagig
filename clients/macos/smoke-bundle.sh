#!/bin/bash
# Native macOS relocation smoke for a built Hagig.app already moved outside the
# checkout. Runs a private disposable server only; never the user's runtime.
set -euo pipefail
usage() { echo 'Usage: bash clients/macos/smoke-bundle.sh /absolute/relocated/Hagig.app' >&2; exit 2; }
fail() { echo "SMOKE FAILED: $*" >&2; exit 1; }
[ "$#" -eq 1 ] || usage
case "$1" in /*) ;; *) usage ;; esac
[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || fail 'requires an Apple Silicon Mac'
mac=$(cd -- "$(dirname -- "$0")" && pwd -P)
root=$(cd -- "$mac/../.." && pwd -P)
[ -d "$1/Contents" ] || fail 'no bundle at that path'
app=$(cd -P -- "$1" && pwd -P)
case "$app/" in "$root"/*) fail 'move the bundle outside the checkout first' ;; esac
contents="$app/Contents"
cli="$contents/Helpers/hagig"
# bundle.sh ships exactly one CPython minor version: bin/python3.N and lib/python3.N.
set -- "$contents"/Resources/python/bin/python3.*
[ "$#" -eq 1 ] && [ -f "$1" ] || fail 'expected exactly one bundled interpreter'
interpreter=$1
site="$contents/Resources/python/lib/${interpreter##*/}/site-packages"
[ -d "$site" ] || fail 'no site-packages beside the interpreter'
wav="$root/backend/tests/fixtures/speech.wav"

echo '== Static: signatures, architectures, loader paths, checkout references'
plutil -lint "$contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$app"
[ -f "$contents/Resources/LICENSE" ] || fail 'LICENSE missing'
machos=$(find "$app" -type f -exec file {} + | sed -n 's/:[[:space:]].*Mach-O.*$//p' |
    sed 's/ (for architecture [^)]*)$//' | LC_ALL=C sort -u)
[ -n "$machos" ] || fail 'no Mach-O files found'
count=0
# Collect every violation across all files, then fail once with the full list.
problems=()
while IFS= read -r binary; do
    count=$((count + 1))
    name=${binary#"$app"/}
    codesign --verify --strict "$binary" 2>/dev/null || problems+=("unsigned or invalid code: $name")
    case " $(lipo -archs "$binary") " in *' arm64 '*) ;; *) problems+=("not arm64: $name") ;; esac
    # Only system libraries and loader-relative paths inside the bundle.
    # Process substitution keeps these loops, and so `problems`, in this shell.
    # -arch arm64: one slice of a universal binary; dependency lines start with a tab.
    own=$(otool -D -arch arm64 "$binary" | tail -n +2)
    while read -r dependency; do
        [ "$dependency" != "$own" ] || continue
        case "$dependency" in
            /usr/lib/*|/System/Library/*|@rpath/*|@loader_path/*|@executable_path/*) ;;
            *) problems+=("absolute loader dependency $dependency in $name") ;;
        esac
    done < <(otool -L -arch arm64 "$binary" | awk '/^\t/ { print $1 }')
    # Search paths: bundle-relative, or the sealed read-only system volume
    # (llvmlite carries /usr/lib), where nothing can be planted.
    while read -r rpath; do
        case "$rpath" in
            @loader_path*|@executable_path*|/usr/lib|/usr/lib/*|/System/Library/*) ;;
            *) problems+=("loader search path $rpath in $name") ;;
        esac
    done < <(otool -l -arch arm64 "$binary" | awk '/cmd LC_RPATH/ { path = 1; next } path && $1 == "path" { print $2; path = 0 }')
done <<< "$machos"
if [ "${#problems[@]}" -gt 0 ]; then
    printf 'SMOKE FAILED: %s\n' "${problems[@]}" >&2
    exit 1
fi
echo "Verified $count Mach-O files: signed, arm64, system or bundle-relative loader paths."
# Where a checkout path could steer imports or execution. (The Swift shell may
# embed source paths as diagnostic strings; that is not a runtime dependency.)
set +e
references=$(grep -rlF -- "$root" "$contents/Resources" "$contents/Helpers")
found=$?
set -e
[ "$found" = 1 ] || fail "bundle names the checkout path (grep $found): ${references//"$app"\//}"
echo 'No Resources or Helpers file names the checkout path.'

scratch=$(mktemp -d /private/tmp/hagig-smoke.XXXXXX)
started=
shell_pid=
cleanup() {
    status=$?
    trap - EXIT
    if [ -n "$shell_pid" ]; then kill "$shell_pid" 2>/dev/null || true; wait "$shell_pid" 2>/dev/null || true; fi
    # Only this disposable runtime is in scope. Retain it if stop fails.
    if [ -n "$started" ] && ! run "$cli" stop; then
        echo "Cleanup failed; retained private smoke directory: $scratch" >&2
        exit 1
    fi
    rm -rf -- "$scratch"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -m 700 "$scratch/run"
mkdir -p "$scratch/home" "$scratch/config/hagig" "$scratch/data"
printf '[model]\nid = "qwen3-asr-0.6b"\n' > "$scratch/config/hagig/config.toml"
# No PATH, uv, PYTHONPATH or developer variables: only a home and private XDG paths.
run() {
    env -i HOME="$scratch/home" XDG_RUNTIME_DIR="$scratch/run" \
        XDG_CONFIG_HOME="$scratch/config" XDG_DATA_HOME="$scratch/data" "$@"
}
field() { printf '%s' "$1" | plutil -extract "$2" raw -o - -; }
socket="$scratch/run/hagig/server.sock"

echo '== Runtime: start, status over the socket, transcribe, Seatbelt, stop'
[ "$(run "$cli" status)" = stopped ] || fail 'a server answered before start'
started=1
run "$cli" start
status=$(run "$cli" status)
echo "$status"
direct=$(curl --silent --show-error --fail --unix-socket "$socket" http://localhost/v1/status)
for json in "$status" "$direct"; do
    [ "$(field "$json" api_version)" = 1 ] && [ "$(field "$json" state)" = idle ] &&
        [ "$(field "$json" worker)" = absent ] && [ "$(field "$json" network_isolation)" = required ] &&
        [ "$(field "$json" settings.model_id)" = qwen3-asr-0.6b ] || fail 'unexpected status'
done
server=$(lsof -t "$scratch/run/hagig/server.lock")
[ "$(ps -ww -o command= -p "$server")" = "$interpreter -I -m hagig.server" ] ||
    fail 'server is not the bundled interpreter'
# Every executable or library the server has mapped is the bundle's or the system's.
lsof -p "$server" -Ffn | awk '/^f/ { text = ($0 == "ftxt") } /^n/ && text { print substr($0, 2) }'
while read -r name; do
    case "$name" in
        # The OS's logging-preference cache is mapped into processes that log; not code.
        "$app"/*|/usr/lib/*|/usr/share/*|/System/*|/private/var/db/dyld/*|/Library/Preferences/Logging/*) ;;
        *) fail "server mapped $name" ;;
    esac
done < <(lsof -p "$server" -Ffn | awk '/^f/ { text = ($0 == "ftxt") } /^n/ && text { print substr($0, 2) }')
echo "Server $server runs the relocated bundled interpreter and maps no code outside the bundle."
set +e
text=$(run "$cli" transcribe "$wav" 2> "$scratch/stderr")
code=$?
set -e
[ "$code" = 1 ] && [ -z "$text" ] && [ "$(cat "$scratch/stderr")" = model_missing ] ||
    fail "transcribe: exit $code, stderr $(head -c 200 "$scratch/stderr")"
echo 'transcribe speech.wav: model_missing (exit 1, empty stdout).'
[ "$(field "$(run "$cli" status)" state)" = idle ] || fail 'not idle after model_missing'

# The engine stack loads from the relocated bundle alone: every native library
# resolves through the bundle's own loader paths. Not inference evidence.
run "$interpreter" -I -c 'import importlib, sys
for name in ("torch", "transformers", "scipy.linalg", "numba", "mlx.core", "mlx_whisper"):
    importlib.import_module(name)
    print("imported", name, getattr(sys.modules[name.split(".")[0]], "__version__", ""))' ||
    fail 'an engine module did not import from the relocated bundle'

# Without a model the server never launches a worker (model_missing is checked
# first), so run the server's own required-mode argv for this bundle directly:
# sandbox-exec with the bundled profile, then the bundled worker, which must
# answer its ready line under the policy and exit 0 at EOF.
run "$interpreter" -I - "$contents" <<'PY'
import os
import subprocess
import sys
from pathlib import Path

from hagig.launcher import Launcher, worker_env

python = Path(sys.argv[1]) / "Resources" / "python"
argv = Launcher().argv("required")
if argv is None:
    sys.exit("SMOKE FAILED: isolation_unavailable (no sandbox-exec or Seatbelt profile)")
sandbox, flag, profile, *command = argv
assert (sandbox, flag) == ("/usr/bin/sandbox-exec", "-f"), argv[:2]
assert Path(profile).is_relative_to(python) and Path(profile).is_file(), profile
assert Path(command[0]).is_relative_to(python), command[0]
done = subprocess.run(
    argv, input=b"", capture_output=True, env=worker_env(os.environ), cwd="/", timeout=60
)
assert done.stdout == b"HAGIG-WORKER-READY-v1\n", done.stdout[:64]
assert done.returncode == 0, done.returncode
print(f"Seatbelt: worker ready under sandbox-exec -f {Path(profile).relative_to(python)}")
PY

run "$cli" stop
started=
[ "$(run "$cli" status)" = stopped ] || fail 'server still answers after stop'
for _ in $(seq 40); do kill -0 "$server" 2>/dev/null || break; sleep 0.05; done
! kill -0 "$server" 2>/dev/null || fail 'server process outlived stop'
[ ! -e "$socket" ] || fail 'socket left behind'

# Launch the relocated real shell executable, observe liveness, stop only our PID.
# This is not LaunchServices/menu/keyboard/TCC/physical-Mac acceptance.
# Not through `run`: a backgrounded function is a subshell, so $! would not be
# the shell's PID, and the shell would outlive the kill holding stdout open.
env -i HOME="$scratch/home" XDG_RUNTIME_DIR="$scratch/run" XDG_CONFIG_HOME="$scratch/config" \
    XDG_DATA_HOME="$scratch/data" "$contents/MacOS/HagigShell" > /dev/null 2>&1 &
shell_pid=$!
sleep 2
kill -0 "$shell_pid" || fail 'relocated shell exited'
[ "$(ps -ww -o command= -p "$shell_pid")" = "$contents/MacOS/HagigShell" ] || fail 'shell PID is not HagigShell'
kill "$shell_pid"; wait "$shell_pid" 2>/dev/null || true
shell_pid=

# The seal covers every file, so this fails if running added (say, __pycache__),
# changed or removed anything in the bundle.
codesign --verify --deep --strict "$app" || fail 'running the bundle changed its files'
echo 'Bundle seal still valid after the run: no file added, changed or removed.'

kib() { du -sk "$1" | awk '{ print $1 }'; }
echo "BUNDLE_INTERPRETER $(run "$interpreter" -I -c 'import platform; print(platform.python_version())')"
echo "BUNDLE_SIZE_KIB app=$(kib "$app") python=$(kib "$contents/Resources/python") site_packages=$(kib "$site") shell=$(kib "$contents/MacOS/HagigShell")"
du -sk "$site"/* | sort -rn | sed -n 1,10p
echo 'BUNDLE_SMOKE_PASSED'
