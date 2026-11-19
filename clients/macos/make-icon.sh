#!/bin/bash
# Renders Resources/Hagig.icns from Resources/AppIcon.svg with macOS's own sips
# and iconutil. Run only after editing the SVG, then inspect and commit the
# result; bundle.sh copies the committed file and never runs this.
set -euo pipefail
mac=$(cd -- "$(dirname -- "$0")" && pwd -P)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/Hagig.iconset"
for size in 16 32 128 256 512; do
    sips -s format png -z "$size" "$size" "$mac/Resources/AppIcon.svg" \
        --out "$work/Hagig.iconset/icon_${size}x${size}.png" >/dev/null
    sips -s format png -z "$((size * 2))" "$((size * 2))" "$mac/Resources/AppIcon.svg" \
        --out "$work/Hagig.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$work/Hagig.iconset" -o "$mac/Resources/Hagig.icns"
echo "Wrote $mac/Resources/Hagig.icns"
