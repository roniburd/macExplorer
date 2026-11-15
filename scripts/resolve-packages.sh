#!/bin/bash
# Resolves SwiftPM dependencies, including binary targets such as Sparkle's release zip downloaded from GitHub,
# retrying with backoff: those downloads sometimes return 5xx (seen as badResponseStatusCode(504) on CI), and a
# single network hiccup should not fail a CI or release run. Only network/HTTP-looking failures are retried; any
# other failure (a bad manifest, a version conflict, a checksum mismatch) fails at once.
# Usage: scripts/resolve-packages.sh [attempts]   (default 5)
#        scripts/resolve-packages.sh --self-test  (checks the error classifier; resolves nothing)
set -euo pipefail
cd "$(dirname "$0")/.."

# is_network_error <log file>: true when swift package resolve's output looks like a transient network/HTTP failure.
is_network_error() {
  grep -Eqi 'badResponseStatusCode|status code (429|5[0-9][0-9])|HTTP (error )?(429|5[0-9][0-9])|timed out|could not resolve host|connection (reset|refused|was lost|closed)|network (connection|is unreachable)|internet connection|failed to connect|unable to access|SSL|TLS|early EOF|RPC failed|remote end hung up|temporary failure' "$1"
}

if [ "${1:-}" = "--self-test" ]; then
  t="$(mktemp -d "${TMPDIR:-/tmp}/macx-resolve-test-XXXXXX")"
  trap 'rm -rf "$t"' EXIT
  check() { printf '%s\n' "$2" > "$t/log"; if is_network_error "$t/log"; then got=retry; else got=fail; fi
            [ "$got" = "$1" ] || { echo "resolve-packages self-test: '$2' -> $got, want $1" >&2; exit 1; }; }
  check retry "error: failed downloading 'https://github.com/x.zip' which is required by binary target 'Sparkle': badResponseStatusCode(504)"
  check retry "fatal: unable to access 'https://github.com/swiftlang/swift-markdown/': Could not resolve host: github.com"
  check retry "error: The request timed out."
  check retry "error: The network connection was lost."
  check retry "fatal: early EOF"
  check fail  "error: Dependencies could not be resolved because root depends on 'sparkle' 2.10.1..2.10.2."
  check fail  "error: checksum of downloaded artifact of binary target 'Sparkle' (abc) does not match checksum specified by the manifest (def)"
  check fail  "error: Invalid manifest"
  echo "resolve-packages self-test: ok"; exit 0
fi

attempts="${1:-5}"
log="$(mktemp "${TMPDIR:-/tmp}/macx-resolve-XXXXXX")"
trap 'rm -f "$log"' EXIT
for i in $(seq 1 "$attempts"); do
  if swift package resolve 2>&1 | tee "$log"; then exit 0; fi
  if ! is_network_error "$log"; then
    echo "::error title=Package resolve::swift package resolve failed with a non-network error; not retrying"
    exit 1
  fi
  [ "$i" -lt "$attempts" ] || break
  delay=$((i * 20))
  echo "::warning title=Package resolve::attempt $i of $attempts failed (network); retrying in ${delay} s"
  sleep "$delay"
done
echo "::error title=Package resolve::swift package resolve failed $attempts times (network or registry outage?)"
exit 1
