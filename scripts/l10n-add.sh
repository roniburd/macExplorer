#!/bin/bash
# scripts/l10n-add.sh: add English String Catalog entries whose key is the English text.
# Usage: scripts/l10n-add.sh "Key one" "Key %@ two" ...
# Output keeps Xcode's catalog format (sorted keys, `"key" : value`), so diffs show only the new entries.
set -euo pipefail
cd "$(dirname "$0")/.."
catalog=Sources/UI/Resources/Localizable.xcstrings
tmp="$(mktemp "${TMPDIR:-/tmp}/macx-xcstrings-XXXXXX")"
jq -S '.strings += ([$ARGS.positional[] | {(.): {"extractionState": "manual", "localizations": {"en": {"stringUnit": {"state": "translated", "value": .}}}}}] | add // {})' \
  "$catalog" --args "$@" | sed -E 's/^( *"([^"\\]|\\.)*"): /\1 : /' > "$tmp"
mv "$tmp" "$catalog"
