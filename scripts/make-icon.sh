#!/bin/bash
# scripts/make-icon.sh: rebuilds Resources/AppIcon.icns from the checked-in PNGs in Resources/AppIcon.iconset.
# The PNGs are the source artwork (the "Glass folder, 72% + halo" design): 16–64 px use a simplified small drawing,
# 128 px and up the full one. To change the icon, replace every PNG at the exact pixel size checked below (sips -g
# pixelWidth <file> shows it), then run this script and commit the PNGs together with Resources/AppIcon.icns.
# Usage: scripts/make-icon.sh
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
iconset="$repo/Resources/AppIcon.iconset"

for spec in 16x16:16 16x16@2x:32 32x32:32 32x32@2x:64 128x128:128 128x128@2x:256 256x256:256 256x256@2x:512 \
            512x512:512 512x512@2x:1024; do
    name="icon_${spec%%:*}.png" px="${spec##*:}"
    [ -f "$iconset/$name" ] || { echo "make-icon.sh: missing $iconset/$name" >&2; exit 1; }
    got="$(sips -g pixelWidth -g pixelHeight "$iconset/$name" | awk '/pixel(Width|Height)/ { printf "%s ", $2 }')"
    [ "$got" = "$px $px " ] || { echo "make-icon.sh: $name is ${got}, expected ${px}x${px}" >&2; exit 1; }
done

iconutil -c icns "$iconset" -o "$repo/Resources/AppIcon.icns"
echo "$repo/Resources/AppIcon.icns"
