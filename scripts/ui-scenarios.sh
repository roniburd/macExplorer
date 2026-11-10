#!/bin/bash
# Bundles the scenario copy of the app and runs every Tests/Scenarios/*.json through it, one app process per
# scenario, inside ONE fresh ${TMPDIR}/macx-scenario-ui-<UUID> run directory. Usage:
#   scripts/ui-scenarios.sh [debug|release] [--filter <substring>] [--timeout <seconds>] [--require-gui] [--keep-sandbox]
# Each scenario gets <run>/<name>/{macx-scenario-root,state,trash}. The app runs with --root, --state-dir,
# --sandbox-trash, a private --pasteboard, --fake-launch-services and --skip-onboarding, so it never writes a real
# user folder, the real Trash, the general pasteboard or real LaunchServices defaults.
# A failed scenario runs once more in a fresh sandbox (<run>/<name>.retry); passing then is reported as a
# `::warning title=Flaky scenario::` and status "flaky" in .build/ui-scenario-report.json (no retry over 5 failures).
# Exit codes: 0 all passed (or no GUI session without --require-gui), 1 a scenario failed, 2 environment, 64 usage.
# On exit: kill our app if it still runs, detach images under the run dir, clear uchg/000, delete the run dir.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
REPO="$(pwd -P)"

usage() { echo "usage: $0 [debug|release] [--filter <substring>] [--timeout <seconds>] [--require-gui] [--keep-sandbox]" >&2; exit 64; }
CONFIG=debug; FILTER=""; TIMEOUT=120; REQUIRE_GUI=0; KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    debug|release) CONFIG="$1" ;;
    --filter) [ $# -ge 2 ] || usage; FILTER="$2"; shift ;;
    --timeout) [ $# -ge 2 ] && [ "$2" -gt 0 ] 2>/dev/null || usage; TIMEOUT="$2"; shift ;;
    --require-gui) REQUIRE_GUI=1 ;;
    --keep-sandbox) KEEP=1 ;;
    *) usage ;;
  esac
  shift
done

APP="$REPO/.build/macExplorer-scenarios.app"
BIN="$APP/Contents/MacOS/macExplorer"
SCEN_DIR="$REPO/Tests/Scenarios"
if LC_ALL=C pgrep -f 'macExplorer-scenarios.app/Contents/MacOS/macExplorer' >/dev/null; then
  echo "ui-scenarios: another scenario app is running; quit it first" >&2; exit 2
fi

TMPBASE="${TMPDIR:-/tmp}"; TMPBASE="${TMPBASE%/}"
RUN="$TMPBASE/macx-scenario-ui-$(uuidgen)"
mkdir "$RUN" || exit 2
RUN_REAL="$(cd "$RUN" && pwd -P)"
APP_PID=""

cleanup() {
  if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then kill -KILL "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null; fi
  case "$RUN" in "$TMPBASE"/macx-scenario-ui-*) ;; *) echo "refusing to clean $RUN" >&2; return 1 ;; esac
  while IFS= read -r mp; do
    case "$mp" in "$RUN_REAL"/*) hdiutil detach "$mp" -force >/dev/null 2>&1 ;; esac
  done < <(mount | sed -n 's/^.* on \(.*\) (.*)$/\1/p')
  # chmod first: chflags cannot descend into a mode-000 folder, so a uchg item inside one would keep its flag.
  chmod -R u+rwx "$RUN" 2>/dev/null
  chflags -R nouchg "$RUN" 2>/dev/null
  chmod -R u+rwx "$RUN" 2>/dev/null
  if [ "$KEEP" = 1 ]; then echo "sandbox root $RUN kept (--keep-sandbox)"; return 0; fi
  rm -rf "$RUN"
  if [ -e "$RUN" ]; then echo "ERROR: run directory $RUN was not removed" >&2; return 1; fi
  echo "sandbox root $RUN removed"
}
trap 'cleanup || exit 1' EXIT
trap 'exit 130' INT TERM

json_string() { printf '"%s"' "$(printf '%s' "$1" | tr -d '\000-\037' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"; }
field() { plutil -extract "$1" raw -o - "$2" 2>/dev/null; }

# launch <scenario dir> <log> [extra app arguments...]: starts the app in the background with the sandbox options.
launch() {
  local dir="$1" log="$2"
  shift 2
  case "$dir" in "$RUN"/*) ;; *) echo "refusing to launch outside $RUN: $dir" >&2; exit 2 ;; esac
  mkdir -p "$dir/macx-scenario-root" "$dir/state" "$dir/trash" || exit 2
  "$BIN" --root "$dir/macx-scenario-root" --state-dir "$dir/state" --sandbox-trash "$dir/trash" \
    --pasteboard "macx-scenario-$(uuidgen)" --fake-launch-services --skip-onboarding "$@" \
    -ApplePersistenceIgnoreState YES > "$log" 2>&1 &
  APP_PID=$!
}

# await_app <seconds>: waits for $APP_PID; kills it after the timeout. Sets APP_CODE (exit code, or "timeout").
await_app() {
  local limit="$1" start
  start=$(date +%s)
  APP_CODE=""
  while kill -0 "$APP_PID" 2>/dev/null; do
    if [ $(( $(date +%s) - start )) -ge "$limit" ]; then kill -KILL "$APP_PID" 2>/dev/null; APP_CODE=timeout; break; fi
    sleep 0.2
  done
  wait "$APP_PID" 2>/dev/null
  local code=$?
  [ -n "$APP_CODE" ] || APP_CODE=$code
  APP_PID=""
}

echo "run directory: $RUN"
TMPDIR="$RUN/" scripts/bundle.sh "$CONFIG" --bundle-id com.macexplorer.app.scenarios --output "$APP" > "$RUN/bundle.log" 2>&1 \
  || { tail -30 "$RUN/bundle.log"; exit 1; }

# GUI probe: the app must open a window titled after its sandbox root (working definition 2).
launch "$RUN/gui-probe" "$RUN/gui-probe.log" --smoke-exit-after 1
await_app 60
title="$(field windowTitles.0 "$RUN/gui-probe/state/smoke.json")"
if [ "$APP_CODE" != 0 ] || [ "$title" != "macx-scenario-root" ]; then
  echo "ui-scenarios: the app opened no window on its sandbox (exit $APP_CODE, title '$title'); no GUI session?"
  tail -10 "$RUN/gui-probe.log" | sed 's/^/    /'
  if [ "$REQUIRE_GUI" = 1 ]; then exit 2; fi
  echo "SKIP: UI scenarios need a logged-in GUI session (pass --require-gui to fail instead)"; exit 0
fi
# A locked screen still opens windows, but none can become key, so a collapsed toolbar search item never expands
# and focus scenarios (filter-in-folder) fail for reasons unrelated to the app. Report it as an environment problem.
if ioreg -n Root -d1 -a 2>/dev/null | plutil -extract IOConsoleUsers xml1 -o - - 2>/dev/null \
    | grep -A1 CGSSessionScreenIsLocked | grep -q '<true/>'; then
  echo "ui-scenarios: the screen is locked (windows cannot become key); unlock it and rerun"
  if [ "$REQUIRE_GUI" = 1 ]; then exit 2; fi
  echo "SKIP: UI scenarios need an unlocked GUI session (pass --require-gui to fail instead)"; exit 0
fi

names=()
for f in "$SCEN_DIR"/*.json; do
  [ -f "$f" ] || continue
  n="$(basename "$f" .json)"
  case "$n" in *[!a-z0-9-]*) echo "ui-scenarios: ignoring unexpected file name $n.json" >&2; continue ;; esac
  if [ -n "$FILTER" ]; then case "$n" in *"$FILTER"*) ;; *) continue ;; esac; fi
  names+=("$n")
done
[ ${#names[@]} -gt 0 ] || { echo "ui-scenarios: no scenario matches '$FILTER'" >&2; exit 64; }

LOGS="$REPO/.build/ui-scenario-logs/$(basename "$RUN")"

# run_scenario <name> <run name>: runs scenario <name> in $RUN/<run name>; sets ms, act and msg (empty = passed).
run_scenario() {
  local n="$1" dir="$RUN/$2" log="$RUN/$2.log" out index
  # P3-13: the fake Spotlight index state for this file (the app never asks the real index in sandbox runs).
  index="$(/usr/bin/plutil -extract indexStatus raw -o - "$SCEN_DIR/$n.json" 2>/dev/null || echo disabled)"
  case "$index" in enabled|disabled|unknown) ;; *) index=disabled ;; esac
  # P4-23: launchArguments ["--keymap", "<name>.json"] (the only allowed form, ScenarioFile.isValidLaunchArguments): the
  # file comes from Tests/Scenarios/keymaps and is copied into this scenario's sandbox before launch.
  local extra=() flag keymap
  flag="$(/usr/bin/plutil -extract launchArguments.0 raw -o - "$SCEN_DIR/$n.json" 2>/dev/null || true)"
  if [ -n "$flag" ]; then
    keymap="$(/usr/bin/plutil -extract launchArguments.1 raw -o - "$SCEN_DIR/$n.json" 2>/dev/null || true)"
    case "$keymap" in *[!a-z0-9.-]*|"") keymap="" ;; *.json) ;; *) keymap="" ;; esac
    if [ "$flag" != "--keymap" ] || [ -z "$keymap" ] || [ ! -f "$SCEN_DIR/keymaps/$keymap" ]; then
      ms=0; act=false; msg="bad launchArguments ($flag $keymap): only --keymap <file in Tests/Scenarios/keymaps>"; return 0
    fi
    mkdir -p "$dir" && cp "$SCEN_DIR/keymaps/$keymap" "$dir/$keymap" || exit 2
    extra=(--keymap "$dir/$keymap")
  fi
  launch "$dir" "$log" --scenario "$SCEN_DIR/$n.json" --scenario-output "$dir/result.json" --index-status "$index" ${extra[@]+"${extra[@]}"}
  await_app "$TIMEOUT"
  out="$dir/result.json"
  ms=0; act=false
  if [ "$APP_CODE" = timeout ]; then
    msg="timed out after $TIMEOUT s (app killed)"
  elif [ ! -s "$out" ]; then
    msg="no result file (app exit $APP_CODE); see $2.log"
  else
    ms="$(field durationMs "$out")"; act="$(field activated "$out")"
    if [ "$(field passed "$out")" = true ] && [ "$APP_CODE" = 0 ]; then msg=""
    else msg="step $(field failedStep "$out" || echo '?'): $(field message "$out") (exit $APP_CODE)"; fi
  fi
  if [ -n "$msg" ]; then
    mkdir -p "$LOGS" && cp "$log" "$LOGS/$2.log" 2>/dev/null && { [ ! -s "$out" ] || cp "$out" "$LOGS/$2.json"; }
  fi
  return 0
}

# add_entry <name> <status> <message>: appends one result to the JSON report (uses ms and act).
add_entry() {
  entries="${entries:+$entries,}{\"name\":$(json_string "$1"),\"status\":\"$2\",\"durationMs\":${ms:-0},\"activated\":${act:-false},\"message\":$(json_string "$3")}"
}

passed=0; flaky=0; failed=0; entries=""; failed_names=(); failed_msgs=()
for n in "${names[@]}"; do
  run_scenario "$n" "$n"
  if [ -z "$msg" ]; then
    passed=$((passed + 1)); add_entry "$n" passed ""
    echo "PASS $n (${ms} ms, activated=${act:-false})"
  else
    failed_names+=("$n"); failed_msgs+=("$msg")
    echo "FAIL $n: $msg"
  fi
done

# Shared CI runners are slow and uneven: each failed scenario runs ONCE more in a fresh sandbox ($RUN/<name>.retry).
# Passing then counts as flaky (a ::warning), not failed. More than MAX_RETRIES (default 5) failures is real
# breakage and is not retried.
MAX_RETRIES="${MAX_RETRIES:-5}"
retry=1
if [ ${#failed_names[@]} -gt "$MAX_RETRIES" ]; then
  retry=0; echo "ui-scenarios: ${#failed_names[@]} scenarios failed (more than $MAX_RETRIES); not retrying"
fi
i=0
while [ "$i" -lt ${#failed_names[@]} ]; do
  n="${failed_names[$i]}"; first="${failed_msgs[$i]}"; i=$((i + 1))
  msg="$first"
  if [ "$retry" = 1 ]; then echo "RETRY $n"; run_scenario "$n" "$n.retry"; fi
  if [ "$retry" = 1 ] && [ -z "$msg" ]; then
    flaky=$((flaky + 1)); add_entry "$n" flaky "first run: $first"
    echo "PASS $n on retry (${ms} ms); first run: $first"
    echo "::warning title=Flaky scenario::UI scenario $n failed then passed on retry (first run: $first)"
    [ -z "${GITHUB_STEP_SUMMARY:-}" ] || printf -- '- Flaky UI scenario `%s` (first run: %s)\n' "$n" "$first" >> "$GITHUB_STEP_SUMMARY"
  else
    failed=$((failed + 1))
    if [ "$retry" = 1 ]; then add_entry "$n" failed "$first; retry: $msg"; echo "FAIL $n again on retry: $msg"
    else add_entry "$n" failed "$first"; fi
  fi
done

mkdir -p "$REPO/.build"
printf '{"results":[%s],"passed":%d,"flaky":%d,"failed":%d}\n' "$entries" "$passed" "$flaky" "$failed" > "$REPO/.build/ui-scenario-report.json"
echo "ui-scenarios: $passed passed, $flaky flaky (passed on retry), $failed failed"
[ ${#failed_names[@]} -eq 0 ] || echo "logs of failed runs: $LOGS"
[ "$failed" -eq 0 ]
