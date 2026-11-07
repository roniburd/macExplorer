#!/bin/bash
# Layering and test-safety checks (spec §4.1, overview Global Constraints, S6 Contract notes C11 and C13,
# Phase 2 plan P2-20 for the Quick Look rules).
# Usage: scripts/check-layering.sh [--root <repository dir>]   (default: the repository containing this script)
# Prints one "RULE <id>: <file>:<line>: <text>" line per violation and exits 1 if there is any, 0 when clean,
# 64 on usage errors. It only reads source files and runs `swift package dump-package`; it writes nothing.
set -uo pipefail

usage() { echo "usage: $0 [--root <repository dir>]" >&2; exit 64; }
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
while [ $# -gt 0 ]; do
  case "$1" in
    --root) [ $# -ge 2 ] && [ -d "$2" ] || usage; ROOT="$(cd "$2" && pwd -P)"; shift ;;
    *) usage ;;
  esac
  shift
done
cd "$ROOT" || exit 64

violations=0

# report <rule> [keep-comments] < "file:line:text" lines. Comment-only lines are ignored unless keep-comments.
report() {
  local rule="$1" keep="${2:-}" line text
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ -z "$keep" ]; then
      text="${line#*:}"; text="${text#*:}"
      if printf '%s\n' "$text" | grep -qE '^[[:space:]]*//'; then continue; fi
    fi
    echo "RULE $rule: $line"
    violations=$((violations + 1))
  done
}

# scan <ERE> <path>...: "file:line:text" for every match in the *.swift files under the existing paths.
scan() {
  local pattern="$1" p
  shift
  local existing=()
  for p in "$@"; do [ -e "$p" ] && existing+=("$p"); done
  [ ${#existing[@]} -gt 0 ] || return 0
  find "${existing[@]}" -type f -name '*.swift' -exec grep -nHE -- "$pattern" {} + 2>/dev/null
}

IMPORT='^[[:space:]]*(@[A-Za-z_]+(\([^)]*\))?[[:space:]]+)*import[[:space:]]+((typealias|struct|class|enum|protocol|let|var|func)[[:space:]]+)?'
END='([^A-Za-z0-9_]|$)'
HARNESS="Sources/macx-bench Sources/macx-scenarios Sources/UI/Scenario"

# 1. MacxFS and Core never import AppKit/Cocoa/SwiftUI, except Sources/Core/Platform (overview AppKit deviation).
report appkit-in-core < <(scan "${IMPORT}(AppKit|Cocoa|SwiftUI)${END}" Sources/FSKit Sources/Core | grep -v '^Sources/Core/Platform/')

# 2. Imports only point down the layers (App → UI → Core → MacxFS → CFSKit).
report upward-import < <(scan "${IMPORT}(Core|UI|macExplorer|MacxFixtures|macx_bench|macx_scenarios)${END}" Sources/FSKit)
report upward-import < <(scan "${IMPORT}(UI|macExplorer|MacxFixtures|macx_bench|macx_scenarios)${END}" Sources/Core)

# 3. Test fixtures never ship in the app.
report fixtures-in-app < <(scan "${IMPORT}(MacxFixtures|macx_bench|macx_scenarios)${END}" Sources/UI Sources/App)

# 4. No shipping target reaches MacxFixtures through Package.swift (direct or transitive dependency).
MANIFEST_CHECK='
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("Package.swift:0:cannot load the manifest (swift package dump-package failed)"); sys.exit(0)
deps = {}
for t in d.get("targets", []):
    names = []
    for dep in t.get("dependencies", []):
        for kind in ("byName", "target", "product"):
            if kind in dep:
                names.append(dep[kind][0])
    deps[t["name"]] = names
def path(start, goal, seen):
    if start == goal:
        return [goal]
    for n in deps.get(start, []):
        if n not in seen:
            p = path(n, goal, seen | {start})
            if p:
                return [start] + p
    return None
for t in ("CFSKit", "MacxFS", "Core", "UI", "macExplorer"):
    if t in deps:
        p = path(t, "MacxFixtures", set())
        if p:
            print("Package.swift:0:target %s reaches MacxFixtures via %s" % (t, " -> ".join(p)))
'
report manifest-fixtures keep < <(swift package dump-package 2>/dev/null | python3 -I -c "$MANIFEST_CHECK")

# 5. Tests and harnesses never touch global user state (overview "Tests never use"). Reading the general
#    pasteboard's changeCount is allowed: verify-phase1.sh compares it before and after a run (C13).
# shellcheck disable=SC2086
report test-globals < <(scan 'UserDefaults\.standard|UserDefaults\(suiteName:|UserDefaultsStorage\(\)|NSPasteboard\.general' Tests $HARNESS \
  | grep -vE 'NSPasteboard\.general\.changeCount[^A-Za-z0-9_.]*$')

# 6. SystemTrash: never in harnesses; in tests only inside a test method whose name ends in "OnDiskImage" (C13).
# shellcheck disable=SC2086
report system-trash < <(scan 'SystemTrash' $HARNESS)
report system-trash < <(
  [ -d Tests ] && find Tests -type f -name '*.swift' -exec awk '
    FNR == 1 { fn = "" }
    /func[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/ {
      match($0, /func[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/); fn = substr($0, RSTART, RLENGTH); sub(/^func[[:space:]]+/, "", fn)
    }
    /SystemTrash\(\)/ { if (fn !~ /OnDiskImage$/) printf "%s:%d:%s\n", FILENAME, FNR, $0 }
  ' {} +)

# 7. Harness files never contain the literal /Users/ (S6 Global Constraints; scope in Contract note C11).
report users-literal keep < <(
  for p in Sources/macx-bench Sources/macx-scenarios Tests/BenchTests Tests/ScenarioRunnerTests; do
    [ -d "$p" ] && grep -rnHF --include='*.swift' '/Users/' "$p"
  done
  for p in Tests/UITests/Scenario*.swift Tests/Scenarios/*.json; do
    [ -f "$p" ] && grep -nHF '/Users/' "$p"
  done
  true)

# 8. At most one @unchecked Sendable / nonisolated(unsafe) per MacxFS/Core file (overview Platform and language).
report unsafe-escape keep < <(
  for p in Sources/FSKit Sources/Core; do [ -d "$p" ] && find "$p" -type f -name '*.swift'; done | while IFS= read -r f; do
    n=$(grep -vE '^[[:space:]]*//' "$f" | grep -cE '@unchecked[[:space:]]+Sendable|nonisolated\(unsafe\)')
    if [ "$n" -gt 1 ]; then
      echo "$f:0:$n concurrency escapes (@unchecked Sendable / nonisolated(unsafe)); at most 1 per file"
    elif [ "$n" -eq 1 ]; then
      echo "note: $f has 1 concurrency escape; its header comment must explain the confinement" >&2
    fi
  done)

# 9. Sparkle is imported in exactly one file (distribution spec §2): everything else talks to UpdateController.
report sparkle-confined < <(scan "${IMPORT}Sparkle${END}" Sources Tests | grep -v '^Sources/UI/Updates/SparkleBridge.swift:')

# 10. Quick Look frameworks are UI-only (Phase 2 plan P2-20): MacxFS and Core never import Quartz, QuickLook,
#     QuickLookUI or QuickLookThumbnailing, except Sources/Core/Platform (as for AppKit, rule 1).
report quicklook-in-core < <(scan "${IMPORT}(Quartz|QuickLookThumbnailing|QuickLook|QuickLookUI)${END}" Sources/FSKit Sources/Core \
  | grep -v '^Sources/Core/Platform/')

# 11. Quick Look is exercised only from UITests (Phase 2 plan P2-20; previews and thumbnails stay on sandbox files).
report quicklook-in-tests < <(scan 'QLPreviewPanel|QLThumbnailGenerator' Tests | grep -v '^Tests/UITests/')

# 12. NSMetadataQuery lives only in Core/Search/SystemMetadataQuery.swift, confined to its private OperationQueue
#     (Phase 3 plan Global Constraints): nothing else, the main thread included, ever touches one.
report metadata-query-confined < <(scan 'NSMetadataQuery([^A-Za-z0-9_]|$)' Sources | grep -v '^Sources/Core/Search/SystemMetadataQuery.swift:')

# 13. Real iCloud downloads only through SystemUbiquitousDownloader (Core/Preview/Ubiquitous.swift); tests never
#     call startDownloadingUbiquitousItem (they use FakeUbiquitousDownloader).
report ubiquitous-download < <(scan 'startDownloadingUbiquitousItem' Sources Tests | grep -v '^Sources/Core/Preview/Ubiquitous.swift:')

# 14. Tests use the fake Spotlight and downloader. Exceptions: LiveSpotlightTests (queries scoped to its own sandbox
#     only) and the SearchServices.forLaunch type check in SearchResultsModelTests (constructing it runs no query).
report search-fakes-in-tests < <(scan 'SystemUbiquitousDownloader|SystemMetadataQuery' Tests \
  | grep -v '^Tests/CoreTests/Search/LiveSpotlightTests.swift:' \
  | grep -vE '^Tests/CoreTests/Search/SearchResultsModelTests.swift:[0-9]+:.*is SystemMetadataQuery')

# 15. Nothing changes Spotlight index state: no mdimport, no mdutil -i/-E/-X/-L… (only `mdutil -s` is allowed).
report spotlight-index-state < <(
  for p in Sources Tests scripts; do
    [ -d "$p" ] && find "$p" -type f \( -name '*.swift' -o -name '*.sh' \) ! -name 'check-layering.sh' ! -name 'test-check-layering.sh' \
      -exec grep -nHE 'mdimport|mdutil' {} + 2>/dev/null
  done | grep -E 'mdimport|mdutil[^"]*[[:space:]]-[iEXLap]([^A-Za-z]|$)|"-[iEX]"')

if [ "$violations" -gt 0 ]; then
  echo "check-layering: $violations violation(s)"
  exit 1
fi
echo "check-layering: OK (15 rules)"
