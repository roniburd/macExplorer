#!/bin/bash
# Runs every Phase 1 gate (overview "Phase 1 working definition" 1-6) and then checks that the runners left
# nothing behind. Gate logs live in ONE fresh ${TMPDIR}/macx-verify-<UUID> run directory, copied to
# .build/verify-phase1/<run>/ before it is deleted. Usage: scripts/verify-phase1.sh [--skip-ui]
# --skip-ui records the two gates that need a GUI session (app-launch, ui-scenarios) as SKIPPED.
# Exit 0 when every gate passed, 1 when any gate failed, 3 when all ran gates passed but GUI gates were skipped.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
REPO="$(pwd -P)"
SKIP_UI=0
for a in "$@"; do case "$a" in --skip-ui) SKIP_UI=1 ;; *) echo "usage: $0 [--skip-ui]" >&2; exit 64 ;; esac; done

TMPBASE="${TMPDIR:-/tmp}"; TMPBASE="${TMPBASE%/}"
RUN="$TMPBASE/macx-verify-$(uuidgen)"
mkdir "$RUN" || exit 2
RUN_REAL="$(cd "$RUN" && pwd -P)"
LOGS="$REPO/.build/verify-phase1/$(basename "$RUN")"
APP_PID=""

cleanup() {
  if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then kill -KILL "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null; fi
  case "$RUN" in "$TMPBASE"/macx-verify-*) ;; *) echo "refusing to clean $RUN" >&2; return 1 ;; esac
  mkdir -p "$LOGS" && cp "$RUN"/*.log "$RUN"/*.json "$LOGS"/ 2>/dev/null
  while IFS= read -r mp; do
    case "$mp" in "$RUN_REAL"/*) hdiutil detach "$mp" -force >/dev/null 2>&1 ;; esac
  done < <(mount | sed -n 's/^.* on \(.*\) (.*)$/\1/p')
  # chmod first: chflags cannot descend into a mode-000 folder, so a uchg item inside one would keep its flag.
  chmod -R u+rwx "$RUN" 2>/dev/null
  chflags -R nouchg "$RUN" 2>/dev/null
  chmod -R u+rwx "$RUN" 2>/dev/null
  rm -rf "$RUN"
  if [ -e "$RUN" ]; then echo "ERROR: run directory $RUN was not removed" >&2; return 1; fi
  echo "sandbox root $RUN removed (logs in $LOGS)"
}
trap 'cleanup || exit 1' EXIT
trap 'exit 130' INT TERM

total=0; failed=0; skipped=0
# gate <name> <command...>: runs the command with its output in $RUN/<name>.log and prints one GATE line.
gate() {
  local name="$1" start code secs
  shift
  start=$(date +%s)
  "$@" > "$RUN/$name.log" 2>&1; code=$?
  secs=$(( $(date +%s) - start ))
  total=$((total + 1))
  if [ $code -eq 0 ]; then
    echo "GATE $name PASS (${secs} s)"
  else
    failed=$((failed + 1))
    echo "GATE $name FAIL (exit $code, ${secs} s); last lines of $name.log:"
    tail -15 "$RUN/$name.log" | sed 's/^/    /'
  fi
}

# build_clean <debug|release>: swift build, failing on any warning line (Swift warnings are already errors).
build_clean() {
  local out code
  out="$(swift build -c "$1" 2>&1)"; code=$?
  printf '%s\n' "$out"
  [ $code -eq 0 ] || return $code
  if printf '%s\n' "$out" | grep -E '(^|[^A-Za-z])warning:'; then echo "build_clean: warnings present"; return 1; fi
}

# app_launch: release bundle + a sandboxed launch of a release copy under the scenarios bundle id (C12).
app_launch() {
  scripts/bundle.sh release || return 1
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' .build/MacExplorer.app/Contents/Info.plist)" = com.macexplorer.app ] || return 1
  codesign --verify --strict .build/MacExplorer.app || return 1
  TMPDIR="$RUN/" scripts/bundle.sh release --bundle-id com.macexplorer.app.scenarios --output .build/macExplorer-scenarios.app || return 1
  local d="$RUN/launch"
  mkdir -p "$d/macx-scenario-root" "$d/state" "$d/trash" || return 1
  .build/macExplorer-scenarios.app/Contents/MacOS/macExplorer --root "$d/macx-scenario-root" --state-dir "$d/state" \
    --sandbox-trash "$d/trash" --pasteboard "macx-scenario-$(uuidgen)" --fake-launch-services --skip-onboarding \
    --smoke-exit-after 2 -ApplePersistenceIgnoreState YES &
  APP_PID=$!
  local start
  start=$(date +%s)
  while kill -0 "$APP_PID" 2>/dev/null; do
    if [ $(( $(date +%s) - start )) -ge 60 ]; then kill -KILL "$APP_PID"; echo "app did not exit within 60 s"; return 1; fi
    sleep 0.2
  done
  wait "$APP_PID"; local code=$?
  APP_PID=""
  [ $code -eq 0 ] || { echo "app exit $code"; return 1; }
  cat "$d/state/smoke.json"
  [ "$(plutil -extract windowTitles.0 raw -o - "$d/state/smoke.json")" = macx-scenario-root ]
}

# bench: release macx-bench with the absolute budgets (exit 2 means over budget on Apple Silicon).
bench() {
  swift run -c release macx-bench --check-budgets --output "$RUN/bench.json"
}

macx_tmp_entries() { ls -1 "$TMPBASE" 2>/dev/null | grep '^macx-' | grep -vx "$(basename "$RUN")" | sort; }
macx_mounts() { mount | sed -n 's/^.* on \(.*\) (.*)$/\1/p' | grep '/macx-' | sort; }
general_changecount() { "$(swift build --show-bin-path)/macx-scenarios" --general-pasteboard-changecount; }
# defaults_digest: hash of the exported domain (stderr dropped: "does not exist" carries a timestamp and pid).
defaults_digest() { defaults export com.macexplorer.app - 2>/dev/null | shasum; }

# safety: overview working definition 6, checked from the outside after every runner finished.
safety() {
  local bad=0 p
  while IFS= read -r p; do
    if [ -e "$p" ]; then echo "LEFT BEHIND: $p"; bad=1; else echo "gone: $p"; fi
  done < <(cat "$RUN"/*.log | sed -n 's/^.*sandbox \(root \)\{0,1\}\(\/.*\) removed.*$/\2/p' | sort -u)
  macx_tmp_entries > "$RUN/tmp-after.txt"
  while IFS= read -r p; do echo "NEW IN TMPDIR: $TMPBASE/$p"; bad=1; done < <(comm -13 "$RUN/tmp-before.txt" "$RUN/tmp-after.txt")
  macx_mounts > "$RUN/mounts-after.txt"
  while IFS= read -r p; do echo "STILL MOUNTED: $p"; bad=1; done < <(comm -13 "$RUN/mounts-before.txt" "$RUN/mounts-after.txt")
  if LC_ALL=C pgrep -f 'macExplorer-scenarios.app/Contents/MacOS/macExplorer' >/dev/null; then echo "scenario app still running"; bad=1; fi
  local after
  after="$(general_changecount)"
  if [ "$after" != "$GENERAL_BEFORE" ]; then
    echo "general pasteboard changeCount changed ($GENERAL_BEFORE -> $after). If you copied something during the run, rerun."
    bad=1
  fi
  [ "$(defaults_digest)" = "$DEFAULTS_BEFORE" ] || { echo "the com.macexplorer.app defaults domain changed"; bad=1; }
  return $bad
}

echo "run directory: $RUN"
macx_tmp_entries > "$RUN/tmp-before.txt"
macx_mounts > "$RUN/mounts-before.txt"
DEFAULTS_BEFORE="$(defaults_digest)"

gate layering scripts/check-layering.sh
gate layering-selftest scripts/test-check-layering.sh
gate build-release build_clean release
gate build-debug build_clean debug
GENERAL_BEFORE="$(general_changecount)"
gate test swift test --parallel
if [ "$SKIP_UI" = 1 ]; then echo "GATE app-launch SKIPPED (--skip-ui)"; skipped=$((skipped + 1)); else gate app-launch app_launch; fi
gate core-scenarios scripts/run-scenarios.sh release
if [ "$SKIP_UI" = 1 ]; then echo "GATE ui-scenarios SKIPPED (--skip-ui)"; skipped=$((skipped + 1)); else gate ui-scenarios scripts/ui-scenarios.sh --require-gui; fi
gate bench bench
gate safety safety

if [ "$failed" -eq 0 ] && [ "$skipped" -eq 0 ]; then
  echo "verify-phase1: $total/$total gates passed"
  exit 0
fi
[ "$failed" -eq 0 ] && { echo "verify-phase1: $total/$total gates passed, $skipped GUI gate(s) SKIPPED (not a full Phase 1 verification)"; exit 3; }
echo "verify-phase1: $failed of $total gates FAILED"
exit 1
