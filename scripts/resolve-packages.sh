#!/bin/bash
# Resolves SwiftPM dependencies, including binary targets such as Sparkle's release zip downloaded from GitHub,
# retrying with backoff: those downloads sometimes return 5xx (seen as badResponseStatusCode(504) on CI), and a
# single network hiccup should not fail a CI or release run. Only network/HTTP-looking failures are retried; any
# other failure (a bad manifest, a version conflict, a checksum mismatch) fails at once. Only the error lines
# (error:/fatal:/warning:, possibly indented under a "Failed to clone" error) are classified, so a progress line such
# as "Fetching https://github.com/apple/swift-nio-ssl" can't make a non-network failure look like one.
# Usage: scripts/resolve-packages.sh [attempts]   (default 5; the wait before retry n is n * RESOLVE_RETRY_DELAY s,
#                                                  default 20)
#        scripts/resolve-packages.sh --self-test  (the classifier, then whole runs against a fake `swift`)
set -euo pipefail
self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$0")/.."

# is_network_error <log file>: true when swift package resolve's error lines look like a transient network/HTTP
# failure.
is_network_error() {
  grep -Ei '^[[:space:]]*(error|fatal|warning):' "$1" | grep -Eqi 'badResponseStatusCode|status code (429|5[0-9][0-9])|HTTP (error )?(429|5[0-9][0-9])|timed out|could not resolve host|connection (reset|refused|was lost|closed)|network (connection|is unreachable)|internet connection|failed to connect|unable to access|SSL[ _](certificate|connect|error|read|write)|TLS (handshake|error)|early EOF|RPC failed|remote end hung up|temporary failure'
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
  check retry "    fatal: unable to access 'https://github.com/x/': LibreSSL SSL_connect: SSL_ERROR_SYSCALL in connection to github.com:443"
  check fail  "error: product 'NIOSSL' required by package 'macexplorer' target 'X' not found in package 'swift-nio-ssl'."
  check fail  "$(printf 'Fetching https://github.com/apple/swift-nio-ssl\nComputing version: request timed out earlier, cached\nerror: Invalid manifest')"

  # Whole runs against a fake swift that fails with FAKE_MESSAGE (or succeeds when it is empty); every call is
  # appended to calls.txt.
  mkdir -p "$t/bin"
  printf '%s\n' '#!/bin/bash' 'echo run >> "$FAKE_DIR/calls.txt"' \
    '[ -n "$FAKE_MESSAGE" ] || exit 0' 'printf "%s\n" "Fetching https://github.com/x" "$FAKE_MESSAGE"; exit 1' > "$t/bin/swift"
  chmod +x "$t/bin/swift"
  run() {  # run <expected exit> <expected swift runs> <message>
    : > "$t/calls.txt"; local rc=0 calls
    PATH="$t/bin:$PATH" FAKE_DIR="$t" FAKE_MESSAGE="$3" RESOLVE_RETRY_DELAY=0 "$self" 3 > "$t/out" 2>&1 || rc=$?
    calls="$(wc -l < "$t/calls.txt" | tr -d ' ')"
    [ "$rc" = "$1" ] && [ "$calls" = "$2" ] \
      || { echo "resolve-packages self-test: '$3' -> exit $rc after $calls runs, want exit $1 after $2" >&2; cat "$t/out" >&2; exit 1; }
  }
  run 0 1 ""
  run 1 1 "error: Invalid manifest"
  run 1 3 "error: failed downloading 'https://github.com/x.zip' which is required by binary target 'Sparkle': badResponseStatusCode(504)"
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
  delay=$((i * ${RESOLVE_RETRY_DELAY:-20}))
  echo "::warning title=Package resolve::attempt $i of $attempts failed (network); retrying in ${delay} s"
  sleep "$delay"
done
echo "::error title=Package resolve::swift package resolve failed $attempts times (network or registry outage?)"
exit 1
