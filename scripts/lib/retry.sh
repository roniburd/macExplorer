#!/bin/bash
# scripts/lib/retry.sh: the retry rule and the FLAKY summary line shared by test-with-retry.sh, run-scenarios.sh and
# ui-scenarios.sh. Source it; it only defines functions. Self-test: scripts/test-with-retry.sh --self-test.
#
#   macx_retry_allowed <failed count>   true when 1 <= count <= MAX_RETRIES (default 2): more failures than that is
#                                       real breakage, not a flaky test, and is not retried
#   macx_flaky_line <what> [names...]   prints "FLAKY: <n> <what> passed only on retry: <names>"; nothing without names
#                                       (call it as  macx_flaky_line "..." ${arr[@]+"${arr[@]}"}  for bash 3.2's set -u)

macx_retry_allowed() { [ "$1" -ge 1 ] && [ "$1" -le "${MAX_RETRIES:-2}" ]; }

macx_flaky_line() {
  local what="$1"; shift
  [ $# -gt 0 ] || return 0
  echo "FLAKY: $# $what passed only on retry: $*"
}
