#!/bin/bash
# scripts/bundle.sh: assembles and signs MacExplorer.app (with an embedded Sparkle.framework) from the SwiftPM build products.
# Usage: scripts/bundle.sh [debug|release] [--bundle-id ID] [--output PATH] [--version X.Y.Z[-beta.N]] [--build N]
#                          [--sign IDENTITY] [--feed-url URL] [--ed-public-key KEY] [--universal]
#   default: debug, com.macexplorer.app, .build/MacExplorer.app, version/build/feed/key from Resources/Info.plist,
#   --sign - (ad-hoc). A real identity (e.g. "Developer ID Application: ...") also gets a secure timestamp.
#   --universal builds arm64 + x86_64.
# Scenario and smoke runs use a separate copy so AppKit's preference writes never touch a real install's domain:
#   scripts/bundle.sh debug --bundle-id com.macexplorer.app.scenarios --output .build/macExplorer-scenarios.app
set -euo pipefail

usage() {
    echo "usage: $0 [debug|release] [--bundle-id ID] [--output PATH] [--version X.Y.Z[-beta.N]] [--build N]" >&2
    echo "       [--sign IDENTITY] [--feed-url URL] [--ed-public-key KEY] [--universal]" >&2
    exit 64
}

repo="$(cd "$(dirname "$0")/.." && pwd)"
config=debug
bundle_id=com.macexplorer.app
output="$repo/.build/MacExplorer.app"
version="" build="" sign_identity="-" feed_url="" ed_key="" universal=0

while [ $# -gt 0 ]; do
    case "$1" in
        debug|release) config="$1" ;;
        --bundle-id) [ $# -ge 2 ] && [ -n "$2" ] || usage; bundle_id="$2"; shift ;;
        --output) [ $# -ge 2 ] && [ -n "$2" ] || usage; output="$2"; shift ;;
        --version) [ $# -ge 2 ] && [ -n "$2" ] || usage; version="$2"; shift ;;
        --build) [ $# -ge 2 ] && [ -n "$2" ] || usage; build="$2"; shift ;;
        --sign) [ $# -ge 2 ] && [ -n "$2" ] || usage; sign_identity="$2"; shift ;;
        --feed-url) [ $# -ge 2 ] && [ -n "$2" ] || usage; feed_url="$2"; shift ;;
        --ed-public-key) [ $# -ge 2 ] && [ -n "$2" ] || usage; ed_key="$2"; shift ;;
        --universal) universal=1 ;;
        -h|--help) usage ;;
        *) echo "bundle.sh: unknown argument $1" >&2; usage ;;
    esac
    shift
done

case "$bundle_id" in
    *[!A-Za-z0-9.-]*|"") echo "bundle.sh: invalid bundle id $bundle_id" >&2; exit 64 ;;
esac
# X.Y.Z with an optional -beta.N suffix (release tags are v<semver> or v<semver>-beta.<n>).
if [ -n "$version" ] && ! printf '%s\n' "$version" | grep -Eqx '[0-9]+\.[0-9]+\.[0-9]+(-beta\.[0-9]+)?'; then
    echo "bundle.sh: invalid --version $version" >&2; exit 64
fi
case "$build" in
    *[!0-9]*) echo "bundle.sh: --build must be digits: $build" >&2; exit 64 ;;
esac
case "$feed_url" in
    ""|https://*) ;;
    *) echo "bundle.sh: --feed-url must be an https URL: $feed_url" >&2; exit 64 ;;
esac
case "$ed_key" in
    *[!A-Za-z0-9+/=]*) echo "bundle.sh: --ed-public-key must be base64: $ed_key" >&2; exit 64 ;;
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
arch_args=()
[ "$universal" -eq 1 ] && arch_args=(--arch arm64 --arch x86_64)
# ${arr[@]+...}: macOS /bin/bash (3.2) treats an empty array as unbound under set -u.
swift build -c "$config" ${arch_args[@]+"${arch_args[@]}"} --product macExplorer
bin="$(swift build -c "$config" ${arch_args[@]+"${arch_args[@]}"} --show-bin-path)"
[ -x "$bin/macExplorer" ] || { echo "bundle.sh: no executable at $bin/macExplorer" >&2; exit 1; }
[ -d "$bin/macExplorer_UI.bundle" ] || { echo "bundle.sh: no resource bundle at $bin/macExplorer_UI.bundle" >&2; exit 1; }
[ -d "$bin/Sparkle.framework" ] || { echo "bundle.sh: no Sparkle.framework at $bin" >&2; exit 1; }

staging="$(mktemp -d "${TMPDIR:-/tmp}/macx-bundle-XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/MacExplorer.app"
exe="$app/Contents/MacOS/macExplorer"
plist="$app/Contents/Info.plist"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$bin/macExplorer" "$exe"
cp Resources/Info.plist "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$plist"
printf 'APPL????' > "$app/Contents/PkgInfo"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp -R "$bin/macExplorer_UI.bundle" "$app/Contents/Resources/macExplorer_UI.bundle"

# Sparkle: ditto keeps the framework's Versions/Current symlinks; the executable finds it through this rpath.
ditto "$bin/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
if ! otool -l "$exe" | grep -A2 LC_RPATH | grep -qF 'path @executable_path/../Frameworks '; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$exe"
fi

[ -z "$version" ] || /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$plist"
[ -z "$build" ] || /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build" "$plist"
[ -z "$feed_url" ] || /usr/libexec/PlistBuddy -c "Set :SUFeedURL $feed_url" "$plist"
[ -z "$ed_key" ] || /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $ed_key" "$plist"

# Inside-out signing (Sparkle's documented order). Ad-hoc signatures cannot carry a secure timestamp;
# a Developer ID signature needs one for notarization.
# Hardened-runtime library validation only loads frameworks signed by the process's Team ID; ad-hoc signatures
# have none, so an ad-hoc app could not load the embedded Sparkle.framework. Ad-hoc builds alone therefore get
# disable-library-validation; Developer ID builds sign everything with one Team ID and keep validation on.
entitlements="$staging/macExplorer.entitlements"
cp Resources/macExplorer.entitlements "$entitlements"
timestamp=--timestamp
if [ "$sign_identity" = "-" ]; then
    timestamp=--timestamp=none
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$entitlements"
fi
sign() { codesign --force --sign "$sign_identity" --options runtime "$timestamp" "$@"; }
sparkle="$app/Contents/Frameworks/Sparkle.framework"
for xpc in "$sparkle"/Versions/B/XPCServices/*.xpc; do
    [ -e "$xpc" ] || continue
    sign --preserve-metadata=entitlements "$xpc"
done
sign "$sparkle/Versions/B/Autoupdate"
sign "$sparkle/Versions/B/Updater.app"
sign "$sparkle"
sign --entitlements "$entitlements" --identifier "$bundle_id" "$exe"
sign --entitlements "$entitlements" "$app"
codesign --verify --deep --strict "$app"

mkdir -p "$(dirname "$output")"
rm -rf "$output"
mv "$app" "$output"
echo "$output"
