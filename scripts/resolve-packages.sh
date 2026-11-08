#!/bin/bash
# Resolves Swift package dependencies (including the Sparkle binary artifact downloaded from GitHub Releases) with
# retries, so a transient download error (e.g. `badResponseStatusCode(504)`) does not fail a CI job before any code
# is built. Used by ci.yml as the first step after Xcode selection; later `swift build`/`run`/`test` reuse the
# resolved checkouts and artifacts in .build/. Usage: scripts/resolve-packages.sh
# - Up to ATTEMPTS (default 5) tries, waiting 15 s, 30 s, 60 s, 120 s between them.
# - Each retry is reported as a `::warning title=Package download retry::` annotation. Exit 1 if every try failed.
set -euo pipefail
cd "$(dirname "$0")/.."

ATTEMPTS="${ATTEMPTS:-5}"
wait=15
for attempt in $(seq 1 "$ATTEMPTS"); do
  if swift package resolve; then
    exit 0
  fi
  if [ "$attempt" -lt "$ATTEMPTS" ]; then
    echo "::warning title=Package download retry::swift package resolve failed (try $attempt of $ATTEMPTS); retrying in ${wait} s"
    sleep "$wait"
    wait=$((wait * 2))
  fi
done
echo "resolve-packages: swift package resolve failed $ATTEMPTS times" >&2
exit 1
