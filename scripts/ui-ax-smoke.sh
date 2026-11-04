#!/bin/bash
# Optional out-of-process Accessibility smoke: launches the scenario bundle on a 4-item sandbox folder and reads
# the window title and the Details row count through System Events (scripts/ui-ax-smoke.applescript).
# Usage: scripts/ui-ax-smoke.sh [--skip-bundle]
# Exit codes: 0 passed, or skipped because this terminal lacks Accessibility/Automation permission (prints SKIP);
# 1 failed; 2 environment. Everything lives in ONE fresh ${TMPDIR}/macx-scenario-ax-<UUID> run directory.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
REPO="$(pwd -P)"
SKIP_BUNDLE=0
for a in "$@"; do case "$a" in --skip-bundle) SKIP_BUNDLE=1 ;; *) echo "usage: $0 [--skip-bundle]" >&2; exit 64 ;; esac; done

APP="$REPO/.build/macExplorer-scenarios.app"
BIN="$APP/Contents/MacOS/macExplorer"

perm="$(osascript -e 'tell application "System Events" to return UI elements enabled' 2>&1)"
if [ "$perm" != "true" ]; then
  echo "SKIP: this terminal lacks Accessibility (or Automation for System Events) permission: $perm"
  echo "      Grant it in System Settings > Privacy & Security > Accessibility to run this smoke."
  exit 0
fi
if LC_ALL=C pgrep -f 'macExplorer-scenarios.app/Contents/MacOS/macExplorer' >/dev/null; then
  echo "ui-ax-smoke: another scenario app is running; quit it first" >&2; exit 2
fi

TMPBASE="${TMPDIR:-/tmp}"; TMPBASE="${TMPBASE%/}"
RUN="$TMPBASE/macx-scenario-ax-$(uuidgen)"
mkdir "$RUN" || exit 2
APP_PID=""
cleanup() {
  if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
    kill -TERM "$APP_PID" 2>/dev/null; sleep 1; kill -KILL "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null
  fi
  case "$RUN" in "$TMPBASE"/macx-scenario-ax-*) ;; *) echo "refusing to clean $RUN" >&2; return 1 ;; esac
  chmod -R u+rwx "$RUN" 2>/dev/null
  rm -rf "$RUN"
  if [ -e "$RUN" ]; then echo "ERROR: run directory $RUN was not removed" >&2; return 1; fi
  echo "sandbox root $RUN removed"
}
trap 'cleanup || exit 1' EXIT
trap 'exit 130' INT TERM

echo "run directory: $RUN"
if [ "$SKIP_BUNDLE" = 0 ]; then
  TMPDIR="$RUN/" scripts/bundle.sh debug --bundle-id com.macexplorer.app.scenarios --output "$APP" > "$RUN/bundle.log" 2>&1 \
    || { tail -30 "$RUN/bundle.log"; exit 1; }
fi
[ -x "$BIN" ] || { echo "ui-ax-smoke: no scenario bundle at $APP" >&2; exit 2; }

ROOT="$RUN/macx-scenario-root"
mkdir -p "$ROOT/sub" "$RUN/state" "$RUN/trash" || exit 2
for f in a.txt b.txt c.txt; do : > "$ROOT/$f" || exit 2; done   # 4 rows: sub, a.txt, b.txt, c.txt

# --smoke-exit-after 30 is a safety net: the app quits by itself even if this script is killed.
"$BIN" --root "$ROOT" --state-dir "$RUN/state" --sandbox-trash "$RUN/trash" --pasteboard "macx-scenario-$(uuidgen)" \
  --fake-launch-services --skip-onboarding --smoke-exit-after 30 -ApplePersistenceIgnoreState YES > "$RUN/app.log" 2>&1 &
APP_PID=$!

out="$(osascript scripts/ui-ax-smoke.applescript "$APP_PID" 4 15 2>&1)"; code=$?
echo "$out" | sed 's/^/  /'
if [ $code -ne 0 ]; then
  case "$out" in *-25211*|*-1719*|*-1743*|*"assistive access"*) echo "SKIP: Accessibility access was refused: $out"; exit 0 ;; esac
  echo "FAIL ui-ax-smoke: osascript exit $code"; exit 1
fi
fails=0
printf '%s\n' "$out" | grep -qx 'title=macx-scenario-root' || { echo "FAIL: window title is not macx-scenario-root"; fails=1; }
printf '%s\n' "$out" | grep -qx 'window=macx.window' || { echo "FAIL: window AXIdentifier is not macx.window"; fails=1; }
printf '%s\n' "$out" | grep -qx 'rows=4' || { echo "FAIL: macx.details does not show 4 rows"; fails=1; }
[ $fails -eq 0 ] && echo "PASS ui-ax-smoke"
[ $fails -eq 0 ]
