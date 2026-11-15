#!/bin/bash
# scripts/l10n-add.sh: add English String Catalog entries whose key is the English text.
# Usage: scripts/l10n-add.sh "Key one" "Key %@ two" ...
# Output keeps Xcode's catalog format (sorted keys, `"key" : value`), so diffs show only the new entries.
# Needs jq (preinstalled on macOS 15 and later; else `brew install jq`).
set -euo pipefail
cd "$(dirname "$0")/.."
command -v jq >/dev/null 2>&1 || { echo "l10n-add.sh: needs jq (brew install jq)" >&2; exit 69; }
[ "$#" -gt 0 ] || { echo "usage: $0 \"Key one\" \"Key %@ two\" ..." >&2; exit 64; }
catalog=Sources/UI/Resources/Localizable.xcstrings
tmp="$(mktemp "${TMPDIR:-/tmp}/macx-xcstrings-XXXXXX")"
trap 'rm -f "$tmp"' EXIT
jq -S '.strings += ([$ARGS.positional[] | {(.): {"extractionState": "manual", "localizations": {"en": {"stringUnit": {"state": "translated", "value": .}}}}}] | add // {})' \
  "$catalog" --args "$@" | sed -E 's/^( *"([^"\\]|\\.)*"): /\1 : /' > "$tmp"
mv "$tmp" "$catalog"
