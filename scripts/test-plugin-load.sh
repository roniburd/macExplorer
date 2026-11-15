#!/bin/bash
# Real plugin loading (spec §5, plan Task 14): compiles Tests/PluginFixture/FixturePlugin.swift against the built
# MacxPluginKit, wraps it as a .macxplugin, launches the scenario app with --plugins-dir and checks smoke.json:
# the good plugin's provider is loaded and a copy declaring API 9.0 is refused. Everything lives in ONE fresh
# ${TMPDIR}/macx-plugin-load-<UUID> directory, removed on exit. Needs a GUI session (it opens a window).
# Usage: scripts/test-plugin-load.sh [debug|release]   Exit 0 pass, 1 fail, 2 environment (or another scenario run
# holds the ${TMPDIR}/macx-scenario-app.lock lock).
# No -e: the script checks every exit status itself.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
. scripts/lib/sandbox.sh
CONFIG="${1:-debug}"
TMPBASE="${TMPDIR:-/tmp}"; TMPBASE="${TMPBASE%/}"
RUN="$TMPBASE/macx-plugin-load-$(uuidgen)"
mkdir "$RUN" || exit 2
APP_PID=""
cleanup() {
  [ -n "$APP_PID" ] && kill -KILL "$APP_PID" 2>/dev/null
  macx_unlock
  case "$RUN" in "$TMPBASE"/macx-plugin-load-*) macx_remove_tree "$RUN" ;; *) echo "refusing to clean $RUN" >&2 ;; esac
}
trap cleanup EXIT

macx_take_scenario_app test-plugin-load || exit 2
TMPDIR="$RUN/" scripts/bundle.sh "$CONFIG" --bundle-id com.macexplorer.app.scenarios --output .build/macExplorer-scenarios.app >"$RUN/bundle.log" 2>&1 \
  || { tail -20 "$RUN/bundle.log"; exit 1; }
BIN="$(swift build -c "$CONFIG" --show-bin-path)"
MODULES="$BIN/Modules"; [ -d "$MODULES" ] || MODULES="$BIN"

# make_plugin <name> <api version>
make_plugin() {
  local p="$RUN/plugins/$1.macxplugin/Contents"
  mkdir -p "$p/MacOS"
  xcrun swiftc -parse-as-library -emit-library -module-name FixturePlugin -I "$MODULES" -L "$BIN" -lMacxPluginKit \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks Tests/PluginFixture/FixturePlugin.swift \
    -o "$p/MacOS/$1" >"$RUN/swiftc-$1.log" 2>&1 || { cat "$RUN/swiftc-$1.log"; return 1; }
  /usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $1" -c "Add :CFBundleName string $1" \
    -c "Add :CFBundleIdentifier string test.macx.$1" -c "Add :CFBundlePackageType string BNDL" \
    -c "Add :CFBundleShortVersionString string 1.0" -c "Add :NSPrincipalClass string FixturePlugin.FixturePlugin" \
    -c "Add :MacxPluginAPIVersion string $2" "$p/Info.plist" >/dev/null
  codesign --force --sign - "$RUN/plugins/$1.macxplugin" >/dev/null 2>&1
}
make_plugin Fixture 1.0 || exit 1
make_plugin FutureFixture 9.0 || exit 1

d="$RUN/launch"; mkdir -p "$d/root" "$d/state" "$d/trash"
macx_app_args "$d/root" "$d/state" "$d/trash"
.build/macExplorer-scenarios.app/Contents/MacOS/macExplorer "${MACX_APP_ARGS[@]}" --plugins-dir "$RUN/plugins" --smoke-exit-after 3 &
APP_PID=$!
start=$(date +%s)
while kill -0 "$APP_PID" 2>/dev/null; do
  [ $(( $(date +%s) - start )) -ge 60 ] && { echo "app did not exit within 60 s"; exit 1; }
  sleep 0.2
done
wait "$APP_PID"; code=$?; APP_PID=""
[ "$code" -eq 0 ] || { echo "app exit $code"; exit 1; }
cat "$d/state/smoke.json"; echo
plutil -extract plugins json -o - "$d/state/smoke.json" | grep -q '"test.fixture-plugin"' || { echo "FAIL: fixture provider not loaded"; exit 1; }
plutil -extract pluginFailures json -o - "$d/state/smoke.json" | grep -q 'FutureFixture.macxplugin: apiMismatch' \
  || { echo "FAIL: API 9.0 plugin not refused"; exit 1; }
echo "test-plugin-load: PASS"
