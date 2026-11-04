#!/bin/bash
# Builds macx-scenarios and runs the whole Core scenario catalog (including disk images and crash/kill
# recovery) inside ONE fresh ${TMPDIR}/macx-scenario-<UUID> run directory. Usage:
#   scripts/run-scenarios.sh [debug|release] [--filter <substring>] [--keep-sandbox]
# Safety: FileManager.temporaryDirectory ignores TMPDIR on macOS, so each scenario Sandbox is a sibling
# ${TMPDIR}/macx-scenario-<UUID>. The CLI appends every sandbox root it creates to <run dir>/sandboxes.txt
# (--manifest) before using it; on exit this script detaches images mounted under the run dir or a listed
# sandbox only, clears uchg/000 inside them, and deletes them. Nothing else is touched.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

CONFIG=debug
if [ "${1:-}" = "debug" ] || [ "${1:-}" = "release" ]; then CONFIG="$1"; shift; fi

TMPBASE="${TMPDIR:-/tmp}"; TMPBASE="${TMPBASE%/}"
RUN="$TMPBASE/macx-scenario-$(uuidgen)"
mkdir "$RUN" || exit 2
RUN_REAL="$(cd "$RUN" && pwd -P)"

TMPBASE_REAL="$(cd "$TMPBASE" && pwd -P)"
MANIFEST="$RUN/sandboxes.txt"

# Detaches images mounted below $1, clears protections and deletes $1.
remove_tree() {
  local dir="$1" real
  real="$(cd "$dir" 2>/dev/null && pwd -P)" || real="$dir"
  while IFS= read -r mp; do
    case "$mp" in "$real"/*) hdiutil detach "$mp" -force >/dev/null 2>&1 ;; esac
  done < <(mount | sed -n 's/^.* on \(.*\) (.*)$/\1/p')
  chflags -R nouchg "$dir" 2>/dev/null
  chmod -R u+rwx "$dir" 2>/dev/null
  rm -rf "$dir"
  if [ -e "$dir" ]; then echo "ERROR: $dir was not removed" >&2; return 1; fi
}

cleanup() {
  case "$RUN" in "$TMPBASE"/macx-scenario-*) ;; *) echo "refusing to clean $RUN" >&2; return 1 ;; esac
  local failed=0
  if [ -f "$MANIFEST" ]; then
    while IFS= read -r sb; do
      # Only direct children of the temporary directory named macx-scenario-*.
      parent="$(dirname "$sb")"; name="$(basename "$sb")"
      case "$name" in macx-scenario-*) ;; *) echo "refusing to clean $sb" >&2; continue ;; esac
      if [ "$parent" != "$TMPBASE_REAL" ] && [ "$parent" != "$TMPBASE" ]; then echo "refusing to clean $sb" >&2; continue; fi
      if [ -e "$sb" ]; then remove_tree "$sb" && echo "leftover scenario sandbox $sb removed" || failed=1; fi
    done < "$MANIFEST"
  fi
  remove_tree "$RUN" || return 1
  [ "$failed" = 0 ] || return 1
  echo "sandbox root $RUN removed"
}
trap 'cleanup || exit 1' EXIT

echo "run directory: $RUN"
swift build -c "$CONFIG" --product macx-scenarios > "$RUN/build.log" 2>&1 || { tail -30 "$RUN/build.log"; exit 1; }
BIN="$(swift build -c "$CONFIG" --show-bin-path)/macx-scenarios"

"$BIN" --require-images --json "$RUN/report.json" --manifest "$MANIFEST" "$@" 2>&1 | tee "$RUN/log.txt"
status=${PIPESTATUS[0]}
mkdir -p .build && cp "$RUN/report.json" .build/scenario-report.json 2>/dev/null
exit "$status"
