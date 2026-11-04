#!/bin/bash
# scripts/bundle.sh: assembles and ad-hoc signs MacExplorer.app from the SwiftPM build products.
# Usage: scripts/bundle.sh [debug|release] [--bundle-id ID] [--output PATH]
#   default: debug, com.macexplorer.app, .build/MacExplorer.app
# Scenario and smoke runs use a separate copy so AppKit's preference writes never touch a real install's domain:
#   scripts/bundle.sh debug --bundle-id com.macexplorer.app.scenarios --output .build/macExplorer-scenarios.app
set -euo pipefail

usage() { echo "usage: $0 [debug|release] [--bundle-id ID] [--output PATH]" >&2; exit 64; }

repo="$(cd "$(dirname "$0")/.." && pwd)"
config=debug
bundle_id=com.macexplorer.app
output="$repo/.build/MacExplorer.app"

while [ $# -gt 0 ]; do
    case "$1" in
        debug|release) config="$1" ;;
        --bundle-id) [ $# -ge 2 ] && [ -n "$2" ] || usage; bundle_id="$2"; shift ;;
        --output) [ $# -ge 2 ] && [ -n "$2" ] || usage; output="$2"; shift ;;
        -h|--help) usage ;;
        *) echo "bundle.sh: unknown argument $1" >&2; usage ;;
    esac
    shift
done

case "$bundle_id" in
    *[!A-Za-z0-9.-]*|"") echo "bundle.sh: invalid bundle id $bundle_id" >&2; exit 64 ;;
esac
case "$output" in
    /*) ;;
    *) output="$(pwd)/$output" ;;
esac
case "$output" in
    *.app) ;;
    *) echo "bundle.sh: --output must end in .app: $output" >&2; exit 64 ;;
esac

# Only ever replace a bundle this script made (a macExplorer executable inside); refuse anything else.
if [ -e "$output" ]; then
    existing="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$output/Contents/Info.plist" 2>/dev/null || true)"
    if [ "$existing" != "macExplorer" ]; then
        echo "bundle.sh: refusing to replace $output (not a macExplorer bundle)" >&2
        exit 73
    fi
fi

cd "$repo"
swift build -c "$config" --product macExplorer
bin="$(swift build -c "$config" --show-bin-path)"
[ -x "$bin/macExplorer" ] || { echo "bundle.sh: no executable at $bin/macExplorer" >&2; exit 1; }
[ -d "$bin/macExplorer_UI.bundle" ] || { echo "bundle.sh: no resource bundle at $bin/macExplorer_UI.bundle" >&2; exit 1; }

staging="$(mktemp -d "${TMPDIR:-/tmp}/macx-bundle-XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/MacExplorer.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/macExplorer" "$app/Contents/MacOS/macExplorer"
cp Resources/Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$app/Contents/Info.plist"
printf 'APPL????' > "$app/Contents/PkgInfo"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp -R "$bin/macExplorer_UI.bundle" "$app/Contents/Resources/macExplorer_UI.bundle"

codesign --force --sign - --options runtime --entitlements Resources/macExplorer.entitlements \
    --identifier "$bundle_id" "$app/Contents/MacOS/macExplorer"
codesign --force --sign - --options runtime --entitlements Resources/macExplorer.entitlements "$app"
codesign --verify --strict "$app"

mkdir -p "$(dirname "$output")"
rm -rf "$output"
mv "$app" "$output"
echo "$output"
