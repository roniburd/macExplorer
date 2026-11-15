#!/bin/bash
# Self-test of scripts/lib/sandbox.sh: tree removal through mode-000 folders and uchg files, the launch arguments, the
# lock (held, released, stale, racing takeovers) and macx_take_scenario_app. Writes only inside its own mktemp
# directory; mounts nothing, launches no app.
# Usage: scripts/test-sandbox-lib.sh   Exit 0 pass, 1 fail.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib/sandbox.sh"
SB="$(mktemp -d "${TMPDIR:-/tmp}/macx-sandbox-lib-test-XXXXXX")"
cleanup() { chmod -R u+rwx "$SB" 2>/dev/null || true; chflags -R nouchg "$SB" 2>/dev/null || true; rm -rf "$SB"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# Removal: a locked file inside a mode-000 folder, which a plain rm -rf (or chflags before chmod) can't delete.
t="$SB/tree"
mkdir -p "$t/closed/inner" && : > "$t/closed/inner/locked.txt" && : > "$t/top.txt"
chflags uchg "$t/closed/inner/locked.txt" "$t/top.txt"
chmod 000 "$t/closed"
macx_remove_tree "$t" || fail "macx_remove_tree returned non-zero"
[ ! -e "$t" ] || fail "macx_remove_tree left $t behind"
macx_remove_tree "$SB/missing" || fail "removing a missing tree should succeed"

# Clearing without removing (run-scenarios.sh --keep-sandbox).
mkdir -p "$SB/keep/closed" && : > "$SB/keep/closed/f" && chflags uchg "$SB/keep/closed/f" && chmod 000 "$SB/keep/closed"
macx_clear_protections "$SB/keep"
[ -e "$SB/keep/closed/f" ] || fail "macx_clear_protections deleted something"
rm -rf "$SB/keep" && [ ! -e "$SB/keep" ] || fail "macx_clear_protections left a protection behind"

# Launch arguments.
macx_app_args /r /s /t
args=" ${MACX_APP_ARGS[*]} "
for want in "--root /r " "--state-dir /s " "--sandbox-trash /t " "--pasteboard macx-scenario-" "--fake-launch-services " \
            "--skip-onboarding " "-ApplePersistenceIgnoreState YES "; do
  case "$args" in *" $want"*) ;; *) fail "macx_app_args lacks '$want': $args" ;; esac
done

# Lock: taken, refused while a live process holds it, released, and taken over when stale.
lock="$SB/test.lock"
macx_lock "$lock" || fail "first macx_lock"
[ "$(cat "$lock/pid")" = "$$" ] || fail "lock pid"
( MACX_LOCK=""; macx_lock "$lock" 2>/dev/null ) && fail "a held lock was taken again"
macx_unlock
[ ! -e "$lock" ] || fail "macx_unlock left the lock"
mkdir "$lock"; sh -c 'echo $$' > "$lock/pid"           # a pid that has exited
macx_lock "$lock" 2>/dev/null || fail "a stale lock (dead pid) was not taken over"
[ "$(cat "$lock/pid")" = "$$" ] || fail "stale takeover pid"
macx_unlock
mkdir "$lock"                                          # just created by someone else, no pid yet
( MACX_LOCK=""; macx_lock "$lock" 2>/dev/null ) && fail "a fresh lock without a pid was taken"
touch -t 200001010000 "$lock"                          # ...and the same lock, long abandoned
macx_lock "$lock" 2>/dev/null || fail "an old lock without a pid was not taken over"
macx_unlock

# A takeover marker left by a process that died mid-takeover: refused while fresh, removed when old (the call still
# returns 1; the next one takes the stale lock).
mkdir "$lock"; sh -c 'echo $$' > "$lock/pid"; mkdir "$lock.takeover"
( MACX_LOCK=""; macx_lock "$lock" 2>/dev/null ) && fail "a stale lock was taken while another takeover was in progress"
touch -t 200001010000 "$lock.takeover"
( MACX_LOCK=""; macx_lock "$lock" 2>/dev/null ) && fail "an abandoned takeover marker counted as a lock"
[ ! -e "$lock.takeover" ] || fail "the abandoned takeover marker was not removed"
macx_lock "$lock" 2>/dev/null || fail "the stale lock was not taken after the abandoned marker went"
macx_unlock

# Racing takeovers: several separate processes see the same stale lock at once; exactly one may win it. Each winner
# keeps running a moment so its pid stays live while the others decide.
racers=8
for round in 1 2 3 4 5; do
  rm -rf "$lock" "$lock.takeover" "$SB/go" "$SB/won"; : > "$SB/won"
  mkdir "$lock"; sh -c 'echo $$' > "$lock/pid"
  pids=()
  for r in $(seq 1 "$racers"); do
    bash -c '. "$1"; while [ ! -e "$3/go" ]; do :; done
             if macx_lock "$2" 2>/dev/null; then echo "$$" >> "$3/won"; sleep 1; fi' _ "$here/lib/sandbox.sh" "$lock" "$SB" &
    pids+=("$!")
  done
  sleep 0.3; : > "$SB/go"
  for p in "${pids[@]}"; do wait "$p" || true; done
  won="$(wc -l < "$SB/won" | tr -d ' ')"
  [ "$won" = 1 ] || fail "round $round: $won of $racers racing takeovers of one stale lock succeeded (want 1)"
  [ ! -e "$lock.takeover" ] || fail "round $round: a takeover marker was left behind"
done
rm -rf "$lock"

# macx_take_scenario_app: returns 2 while another live process holds the scenario lock.
MACX_SCENARIO_LOCK="$SB/scenario.lock"
mkdir "$MACX_SCENARIO_LOCK"; echo "$PPID" > "$MACX_SCENARIO_LOCK/pid"
code=0; ( MACX_LOCK=""; macx_take_scenario_app self-test 2>/dev/null ) || code=$?
[ "$code" = 2 ] || fail "macx_take_scenario_app returned $code with the lock held, want 2"
rm -rf "$MACX_SCENARIO_LOCK"
echo "sandbox lib self-test: ok"
