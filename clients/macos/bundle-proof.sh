#!/bin/bash
# Counterfactuals for the relocation smoke: each mutant is a copy of a relocated
# Hagig.app with one property broken, and the smoke must refuse it for that
# reason. The original bundle is never changed, and it must still pass after.
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
mkdir "$output"
scratch=$(mktemp -d /private/tmp/hagig-proof.XXXXXX)
trap 'rm -rf -- "$scratch"' EXIT
{ git -C "$root" rev-parse HEAD; sw_vers; uname -m; shasum -a 256 "$0" "$mac/smoke-bundle.sh"; } > "$output/environment.txt"

smoke() { bash "$mac/smoke-bundle.sh" "$1" > "$2" 2>&1; }

for experiment in checkout-link missing-profile unsigned-extension; do
    directory="$output/$experiment"
    mkdir "$directory"
    echo UNPROVEN > "$directory/verdict.txt"
    copy="$scratch/$experiment/Hagig.app"
    mkdir "$scratch/$experiment"
    cp -R "$app" "$copy"
    set -- "$copy"/Contents/Resources/python/lib/python3.*/site-packages
    site=$1
    interpreter=$(echo "$copy"/Contents/Resources/python/bin/python3.*)
    case "$experiment" in
        checkout-link)
            # What an editable install leaves: the package found through the checkout.
            rm -rf "$site/hagig"
            printf '%s\n' "$root/backend/src" > "$site/hagig_checkout.pth"
            expected='bundle names the checkout path'
            ;;
        missing-profile)
            rm "$site/launcher/seatbelt-v1.sb"
            expected='isolation_unavailable'
            ;;
        unsigned-extension)
            set -- "$site"/pydantic_core/_pydantic_core.*.so
            codesign --remove-signature "$1"
            expected='_pydantic_core'
            ;;
    esac
    # Reseal the outer bundle so only the intended property is broken.
    codesign --force --sign - --timestamp=none "$copy"
    case "$experiment" in
        checkout-link)
            # The CLI still runs, from the checkout: runtime success alone misses this.
            env -i HOME="$scratch" "$copy/Contents/Helpers/hagig" --help > /dev/null
            echo 'helper --help: exit 0 (imports hagig through the checkout)' > "$directory/observation.txt"
            ;;
        unsigned-extension)
            set +e
            env -i HOME="$scratch" "$interpreter" -I -c 'import pydantic_core' > "$directory/import.log" 2>&1
            code=$?
            set -e
            echo "import pydantic_core with the unsigned extension: exit $code" > "$directory/observation.txt"
            [ "$code" != 0 ] || { echo 'unsigned extension loaded' >&2; exit 1; }
            ;;
    esac
    if smoke "$copy" "$directory/smoke.log"; then
        echo "$experiment: smoke passed a broken bundle" >&2
        exit 1
    fi
    grep -F -- "$expected" "$directory/smoke.log" > /dev/null || {
        echo "$experiment: smoke failed for another reason" >&2
        tail -n 20 "$directory/smoke.log" >&2
        exit 1
    }
    echo PROVEN > "$directory/verdict.txt"
    echo "$experiment: refused as expected ($expected)"
    rm -rf -- "${scratch:?}/$experiment"
done

mkdir "$output/restored"
smoke "$app" "$output/restored/smoke.log"
grep -Fx BUNDLE_SMOKE_PASSED "$output/restored/smoke.log" > /dev/null
echo 'restored: the original relocated bundle still passes'
echo BUNDLE_PROOF_PASSED
