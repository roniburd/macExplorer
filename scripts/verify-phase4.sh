#!/bin/bash
# Phase 4 "working" definition, reduced scope (owner decisions 2026-11-09: no tags; dual pane, the privileged helper
# and network moved to Phase 6; Sparkle, the release pipeline and Homebrew already ship on main):
#   1. every Phase 1 gate (scripts/verify-phase1.sh: layering, warning-free release + debug builds, swift test --parallel,
#      app launch, core + UI scenarios, bench budgets, safety/cleanliness), then
#   2. every Phase 4 core scenario family (archive., batch., acl., icon., keymap.) passed,
#   3. every Tests/Scenarios/p4-*.json UI scenario ran and passed (skipped with --skip-ui),
#   4. the Phase 4 bench budgets (palette.rank, batchRename.preview) were measured and passed.
# verify-phase1.sh keeps its gate logs in .build/verify-phase1/<run>/; this script only reads them. It creates no
# files of its own outside that log folder. Usage: scripts/verify-phase4.sh [--skip-ui]
# Exit 0 all passed, 1 a check failed, 3 everything ran passed but the GUI gates were skipped.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
SKIP_UI=0
for a in "$@"; do case "$a" in --skip-ui) SKIP_UI=1 ;; *) echo "usage: $0 [--skip-ui]" >&2; exit 64 ;; esac; done
log() { printf '[verify-phase4] %s\n' "$*"; }

log "1/4 Phase 1 gates (scripts/verify-phase1.sh $*)"
out="$(scripts/verify-phase1.sh "$@" 2>&1)"; code=$?
printf '%s\n' "$out"
if [ $code -ne 0 ] && [ $code -ne 3 ]; then log "verify-phase1 failed (exit $code)"; exit 1; fi
logs="$(printf '%s\n' "$out" | sed -n 's/^.*(logs in \(.*\))$/\1/p' | tail -1)"
case "$logs" in "$(pwd -P)"/.build/verify-phase1/macx-verify-*) ;; *) log "cannot find the gate logs ('$logs')"; exit 1 ;; esac

bad=0
log "2/4 Phase 4 core scenarios"
for family in archive. batch. acl. icon. keymap.; do
  passed="$(grep -c "^PASS $family" "$logs/core-scenarios.log" 2>/dev/null || true)"
  if [ "${passed:-0}" -eq 0 ] || grep -q "^FAIL $family" "$logs/core-scenarios.log"; then
    log "core family $family: not all passed"; bad=1
  else
    log "core family $family: $passed passed"
  fi
done

log "3/4 Phase 4 UI scenarios"
if [ "$SKIP_UI" = 1 ]; then
  log "SKIPPED (--skip-ui)"
else
  for f in Tests/Scenarios/p4-*.json; do
    n="$(basename "$f" .json)"
    if grep -q "^PASS $n " "$logs/ui-scenarios.log"; then log "$n passed"; else log "$n did not pass"; bad=1; fi
  done
fi

log "4/4 Phase 4 bench budgets"
for metric in palette.rank batchRename.preview; do
  result="$(plutil -extract budgets json -o - "$logs/bench.json" 2>/dev/null \
    | python3 -I -c 'import json,sys; m=sys.argv[1]; c=[x for x in json.load(sys.stdin) if x["metric"]==m]; print("missing" if not c else ("pass %.2f %s (limit %g)" % (c[0]["median"], c[0]["unit"], c[0]["limit"]) if all(x["passed"] for x in c) else "FAIL"))' "$metric")"
  log "$metric: ${result:-missing}"
  case "$result" in pass*) ;; *) bad=1 ;; esac
done

if [ $bad -ne 0 ]; then log "FAILED"; exit 1; fi
if [ $code -eq 3 ] || [ "$SKIP_UI" = 1 ]; then log "OK, but the GUI gates were skipped (not a full Phase 4 verification)"; exit 3; fi
log "OK"
