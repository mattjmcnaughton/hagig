#!/bin/bash
# Counterfactuals for the bundle checks. Each experiment breaks one property of a
# copy of a relocated Hagig.app, and its check (the relocation smoke, or the app
# test against the bundled server) must refuse that copy for that reason. The
# original is never changed and must pass both checks again afterwards. The app
# experiments need `swift test` already built (the workflow's integration step).
set -euo pipefail
usage() { echo 'Usage: bash clients/macos/bundle-proof.sh /absolute/relocated/Hagig.app /absolute/new/evidence' >&2; exit 2; }
[ "$#" -eq 2 ] || usage
case "$1" in /*) ;; *) usage ;; esac
case "$2" in /*) ;; *) usage ;; esac
test "$(uname -s)" = Darwin
mac=$(cd -- "$(dirname -- "$0")" && pwd -P)
root=$(cd -- "$mac/../.." && pwd -P)
app=$(cd -P -- "$1" && pwd -P)
output=$2
wav="$root/backend/tests/fixtures/speech.wav"
mkdir "$output"
scratch=$(mktemp -d /private/tmp/hagig-proof.XXXXXX)
trap 'rm -rf -- "$scratch"' EXIT
{ git -C "$root" rev-parse HEAD; sw_vers; uname -m; shasum -a 256 "$0" "$mac/smoke-bundle.sh"; } > "$output/environment.txt"

smoke() { bash "$mac/smoke-bundle.sh" "$1"; }
app_test() {
    (cd -- "$mac" && HAGIG_BUNDLED_APP="$1" HAGIG_INTEGRATION_WAV="$wav" \
        swift test --skip-build --filter "BundledBackendTests${2:+/$2}")
}

# Each experiment mutates $copy (whose packages are in $site), may record an
# observation in $directory, and sets $check and the $expected refusal text.
checkout_link() {
    # What an editable install leaves: the package found through the checkout.
    rm -rf "$site/hagig"
    printf '%s\n' "$root/backend/src" > "$site/hagig_checkout.pth"
    # The CLI still runs, from the checkout: runtime success alone misses this.
    env -i HOME="$scratch" "$copy/Contents/Helpers/hagig" --help > /dev/null
    echo 'helper --help: exit 0 (imports hagig through the checkout)' > "$directory/observation.txt"
    check=smoke expected='bundle names the checkout path'
}
missing_profile() {
    rm "$site/hagig/seatbelt-v1.sb"
    check=smoke expected='isolation_unavailable'
}
unsigned_extension() {
    set -- "$site"/pydantic_core/_pydantic_core.*.so
    codesign --remove-signature "$1"
    # Recorded, not asserted: macOS loads it in this unhardened process (seen on
    # macos-15), so the build and the smoke are what enforce signing.
    local code=0
    env -i HOME="$scratch" "$interpreter" -I -c 'import pydantic_core' > "$directory/import.log" 2>&1 || code=$?
    echo "import pydantic_core with the unsigned extension: exit $code" > "$directory/observation.txt"
    check=smoke expected='_pydantic_core'
}
build_host_rpath() {
    # What scipy's wheel shipped: a search path into a build machine's Homebrew.
    set -- "$site"/pydantic_core/_pydantic_core.*.so
    install_name_tool -add_rpath /opt/homebrew/lib "$1"
    codesign --force --sign - --timestamp=none "$1"
    check=smoke expected='loader search path /opt/homebrew/lib'
}
app_without_backend() {
    rm -rf "$site/hagig"
    check=app expected='serverUnavailable'
}

for experiment in checkout_link missing_profile unsigned_extension build_host_rpath app_without_backend; do
    directory="$output/$experiment"
    mkdir "$directory"
    echo UNPROVEN > "$directory/verdict.txt"
    copy="$scratch/$experiment/Hagig.app"
    mkdir "$scratch/$experiment"
    # APFS clones: a full copy of an engine-sized bundle per experiment would
    # cost minutes and gigabytes; mutating a clone copies only what it changes.
    cp -cR "$app" "$copy"
    set -- "$copy"/Contents/Resources/python/bin/python3.*
    interpreter=$1
    site="$copy/Contents/Resources/python/lib/${interpreter##*/}/site-packages"
    "$experiment"
    # Reseal the outer bundle so only the intended property is broken.
    codesign --force --sign - --timestamp=none "$copy"
    if [ "$check" = smoke ]; then
        result=0; smoke "$copy" > "$directory/check.log" 2>&1 || result=$?
    else
        result=0; app_test "$copy" testRecordingReachesTheBundledServerAndShowsModelMissing \
            > "$directory/check.log" 2>&1 || result=$?
    fi
    [ "$result" != 0 ] || { echo "$experiment: $check passed a broken bundle" >&2; exit 1; }
    grep -F -- "$expected" "$directory/check.log" > /dev/null || {
        echo "$experiment: $check failed for another reason" >&2
        tail -n 20 "$directory/check.log" >&2
        exit 1
    }
    echo PROVEN > "$directory/verdict.txt"
    echo "$experiment: $check refused it as expected ($expected)"
    rm -rf -- "${scratch:?}/$experiment"
done

mkdir "$output/restored"
smoke "$app" > "$output/restored/smoke.log" 2>&1
grep -Fx BUNDLE_SMOKE_PASSED "$output/restored/smoke.log" > /dev/null
app_test "$app" > "$output/restored/app.log" 2>&1
grep -E 'Executed 2 tests, with 0 failures' "$output/restored/app.log" > /dev/null
echo 'restored: the original relocated bundle passes the smoke and the app test again'
echo BUNDLE_PROOF_PASSED
