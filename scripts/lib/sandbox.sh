#!/bin/bash
# scripts/lib/sandbox.sh: helpers shared by the runner scripts that make throwaway sandboxes under $TMPDIR and launch
# the scenario copy of the app in them. Source it (`. "$(dirname "$0")/lib/sandbox.sh"`); it only defines functions
# and changes no shell options. Self-test: scripts/test-sandbox-lib.sh.
#
#   macx_detach_under <dir>          force-detaches every disk image mounted below <dir> (its real path is used)
#   macx_clear_protections <dir>     makes everything below <dir> deletable again (mode 000 folders, uchg flags)
#   macx_remove_tree <dir>           both of the above, then rm -rf <dir>; returns 1 when <dir> is still there
#   macx_app_args <root> <state> <trash>
#                                    sets the MACX_APP_ARGS array to the options every sandboxed app launch uses
#   macx_lock <lock dir>             takes an exclusive lock (mkdir is atomic); returns 1 when a live process holds it
#   macx_unlock                      releases the lock this shell took (no-op otherwise)

# macx_mount_points: every mount point, one per line.
macx_mount_points() { mount | sed -n 's/^.* on \(.*\) (.*)$/\1/p'; }

macx_detach_under() {
  local real mp
  real="$(cd "$1" 2>/dev/null && pwd -P)" || real="$1"
  while IFS= read -r mp; do
    case "$mp" in "$real"/*) hdiutil detach "$mp" -force >/dev/null 2>&1 || true ;; esac
  done < <(macx_mount_points)
}

macx_clear_protections() {
  # chmod first: chflags cannot descend into a mode-000 folder, so a uchg item inside one would keep its flag.
  chmod -R u+rwx "$1" 2>/dev/null || true
  chflags -R nouchg "$1" 2>/dev/null || true
  chmod -R u+rwx "$1" 2>/dev/null || true
}

macx_remove_tree() {
  macx_detach_under "$1"
  macx_clear_protections "$1"
  rm -rf "$1" 2>/dev/null || true
  if [ -e "$1" ]; then echo "ERROR: $1 was not removed" >&2; return 1; fi
}

# The sandbox every scripted launch uses: a private pasteboard, a sandbox Trash, fake LaunchServices, no onboarding and
# no saved window state, so the app never writes a real user folder, the real Trash or the general pasteboard.
macx_app_args() {
  MACX_APP_ARGS=(--root "$1" --state-dir "$2" --sandbox-trash "$3" --pasteboard "macx-scenario-$(uuidgen)"
                 --fake-launch-services --skip-onboarding -ApplePersistenceIgnoreState YES)
}

# The lock every script that launches the scenario app takes, across all worktrees: UI runs need keyboard focus, so
# only one may run on the Mac at a time.
MACX_SCENARIO_LOCK="${TMPDIR:-/tmp}"; MACX_SCENARIO_LOCK="${MACX_SCENARIO_LOCK%/}/macx-scenario-app.lock"
MACX_LOCK=""

# A lock records its owner's pid in <lock>/pid. It is stale when that pid no longer runs, or when it has no pid file
# and is older than 30 s (a holder writes the file right after mkdir). A stale lock is taken over.
macx_lock() {
  local lock="$1" pid age
  if ! mkdir "$lock" 2>/dev/null; then
    pid="$(cat "$lock/pid" 2>/dev/null || true)"
    if [ -n "$pid" ]; then
      if kill -0 "$pid" 2>/dev/null; then echo "lock $lock is held by pid $pid" >&2; return 1; fi
    else
      age=$(( $(date +%s) - $(stat -f %m "$lock" 2>/dev/null || date +%s) ))
      if [ "$age" -lt 30 ]; then echo "lock $lock is being taken by another process" >&2; return 1; fi
    fi
    echo "taking over the stale lock $lock${pid:+ (pid $pid is gone)}" >&2
    rm -rf "$lock"
    mkdir "$lock" 2>/dev/null || { echo "lock $lock was taken by another process" >&2; return 1; }
  fi
  echo "$$" > "$lock/pid"
  MACX_LOCK="$lock"
}

macx_unlock() {
  [ -n "$MACX_LOCK" ] || return 0
  [ "$(cat "$MACX_LOCK/pid" 2>/dev/null || true)" != "$$" ] || rm -rf "$MACX_LOCK"
  MACX_LOCK=""
}
