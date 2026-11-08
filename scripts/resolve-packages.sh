#!/bin/bash
# Resolves SwiftPM dependencies, including binary targets such as Sparkle's release zip downloaded from GitHub,
# retrying with backoff: those downloads sometimes return 5xx (seen as badResponseStatusCode(504) on CI), and a
# single network hiccup should not fail a CI or release run. Usage: scripts/resolve-packages.sh [attempts]
set -euo pipefail
attempts="${1:-5}"
for i in $(seq 1 "$attempts"); do
  if swift package resolve; then exit 0; fi
  [ "$i" -lt "$attempts" ] || break
  delay=$((i * 20))
  echo "::warning title=Package resolve::attempt $i of $attempts failed; retrying in ${delay} s"
  sleep "$delay"
done
echo "::error title=Package resolve::swift package resolve failed $attempts times (network or registry outage?)"
exit 1
