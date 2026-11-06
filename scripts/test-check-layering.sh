#!/bin/bash
# Self-test for scripts/check-layering.sh. Builds small fake repositories inside ONE fresh
# ${TMPDIR}/macx-tests-<UUID> directory, injects one violation per case, and checks the rule that fires.
# Usage: scripts/test-check-layering.sh      Exit 0 when every case behaves, 1 otherwise.
set -uo pipefail
CHECK="$(cd "$(dirname "$0")" && pwd -P)/check-layering.sh"

TMPBASE="${TMPDIR:-/tmp}"; TMPBASE="${TMPBASE%/}"
SB="$TMPBASE/macx-tests-$(uuidgen)"
mkdir "$SB" || exit 2
cleanup() {
  case "$SB" in "$TMPBASE"/macx-tests-*) rm -rf "$SB" ;; *) echo "refusing to clean $SB" >&2; return 1 ;; esac
  echo "sandbox root $SB removed"
}
trap 'cleanup || exit 1' EXIT

# put <case> <relative path> <content>: writes a file inside $SB/<case> only.
put() {
  case "$1/$2" in *..*|/*) echo "refusing path $1/$2" >&2; exit 2 ;; esac
  mkdir -p "$(dirname "$SB/$1/$2")" && printf '%s\n' "$3" > "$SB/$1/$2"
}
new_case() { cp -R "$SB/clean" "$SB/$1"; }

# manifest <Core dependencies> <UI dependencies> [extra target lines]: a small manifest with the real layering.
manifest() {
  cat <<SWIFT
// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "LayeringFixture",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "CFSKit"),
        .target(name: "MacxFS", dependencies: ["CFSKit"], path: "Sources/FSKit"),
        .target(name: "Core", dependencies: [$1]),
        .target(name: "UI", dependencies: [$2]),
        .executableTarget(name: "macExplorer", dependencies: ["UI", "Core"], path: "Sources/App"),
        .target(name: "MacxFixtures", dependencies: ["MacxFS"]),
        .executableTarget(name: "macx-scenarios", dependencies: ["Core", "MacxFixtures"]),
        .testTarget(name: "CoreTests", dependencies: ["Core", "MacxFixtures"]),${3:-}
    ]
)
SWIFT
}
put clean Package.swift "$(manifest '"MacxFS"' '"Core", "MacxFS"')"
put clean Sources/FSKit/Lane.swift $'import Foundation\nimport CFSKit'
put clean Sources/Core/Model.swift $'import Foundation\nimport MacxFS\n// never import AppKit here'
put clean Sources/Core/Platform/Pasteboard.swift $'import AppKit\nimport MacxFS'
put clean Sources/Core/OneEscape.swift $'// Confined to one lane thread (header comment explains the @unchecked Sendable below).\nfinal class Box: @unchecked Sendable {}'
put clean Sources/UI/View.swift $'import AppKit\nimport SwiftUI\n@preconcurrency import Core'
put clean Sources/App/main.swift $'import AppKit\nimport UI'
put clean Sources/macx-scenarios/CLI.swift $'import Core\nimport MacxFixtures\nprint(NSPasteboard.general.changeCount)'
put clean Tests/CoreTests/ModelTests.swift $'import XCTest\n@testable import Core\n// never NSPasteboard.general\nfinal class ModelTests: XCTestCase {\n    func testBreadcrumbMath() { _ = "/Users/alice/Desktop" }\n    func testSystemTrashOnDiskImage() { _ = try? SystemTrash().trash(url) }\n}'
put clean Tests/Scenarios/a.json '{"name": "a", "fixture": {"files": ["/tmp/x"], "dirs": []}, "steps": []}'

fails=0
# run_case <case> <expected exit> [rule that must fire]
run_case() {
  local name="$1" want="$2" rule="${3:-}" out code
  out="$("$CHECK" --root "$SB/$name" 2>&1)"; code=$?
  if [ "$code" -ne "$want" ]; then
    echo "FAIL $name: exit $code, expected $want"; printf '%s\n' "$out" | sed 's/^/    /'; fails=$((fails + 1)); return
  fi
  if [ -n "$rule" ] && ! printf '%s\n' "$out" | grep -q "^RULE $rule: "; then
    echo "FAIL $name: no 'RULE $rule' line"; printf '%s\n' "$out" | sed 's/^/    /'; fails=$((fails + 1)); return
  fi
  echo "ok   $name"
}

run_case clean 0

new_case appkit-in-core;   put appkit-in-core Sources/Core/Model/Bad.swift 'import AppKit'
new_case swiftui-in-fs;    put swiftui-in-fs Sources/FSKit/Bad.swift '@preconcurrency import SwiftUI'
new_case class-import;     put class-import Sources/Core/Bad.swift 'import class AppKit.NSWorkspace'
new_case fs-imports-core;  put fs-imports-core Sources/FSKit/Bad.swift 'import Core'
new_case core-imports-ui;  put core-imports-ui Sources/Core/Bad.swift '@testable import UI'
new_case ui-fixtures;      put ui-fixtures Sources/UI/Bad.swift 'import MacxFixtures'
new_case manifest;         put manifest Package.swift "$(manifest '"MacxFS"' '"Core", "MacxFS", "MacxFixtures"')"
new_case manifest-transitive
put manifest-transitive Package.swift "$(manifest '"MacxFS", "Helpers"' '"Core", "MacxFS"' '
        .target(name: "Helpers", dependencies: ["MacxFixtures"]),')"
new_case defaults;         put defaults Tests/CoreTests/Bad.swift '    let d = UserDefaults.standard'
new_case suite;            put suite Tests/CoreTests/Bad.swift '    let d = UserDefaults(suiteName: "x")'
new_case storage;          put storage Tests/CoreTests/Bad.swift '    let s = UserDefaultsStorage()'
new_case general;          put general Tests/UITests/Bad.swift '    NSPasteboard.general.clearContents()'
new_case harness-general;  put harness-general Sources/macx-bench/Bad.swift 'NSPasteboard.general.writeObjects([])'
new_case trash-in-test;    put trash-in-test Tests/CoreTests/Bad.swift $'func testTrash() {\n    _ = try? SystemTrash().trash(u)\n}'
new_case trash-in-helper;  put trash-in-helper Tests/CoreTests/Bad.swift $'func testSystemTrashOnDiskImage() {}\nfunc helper() { _ = SystemTrash() }'
new_case trash-harness;    put trash-harness Sources/macx-scenarios/Bad.swift 'let t: any TrashService = SystemTrash()'
new_case users-json;       put users-json Tests/Scenarios/b.json '{"name": "b", "fixture": {"files": ["/Users/me/x"], "dirs": []}, "steps": []}'
new_case users-bench;      put users-bench Sources/macx-bench/Bad.swift '// e.g. /Users/me'
new_case users-uitest;     put users-uitest Tests/UITests/ScenarioBadTests.swift 'let p = "/Users/me"'
new_case users-other-ok;   put users-other-ok Tests/UITests/BreadcrumbTests.swift 'let p = "/Users/me"'
new_case platform-ok;      put platform-ok Sources/Core/Platform/Workspace.swift 'import AppKit'
new_case two-escapes;      put two-escapes Sources/Core/Bad.swift $'final class A: @unchecked Sendable {}\nnonisolated(unsafe) var b = 0'
new_case sparkle-elsewhere; put sparkle-elsewhere Sources/UI/Settings/Bad.swift 'import Sparkle'
new_case sparkle-in-test;  put sparkle-in-test Tests/UITests/Bad.swift '@testable import Sparkle'
new_case sparkle-bridge-ok; put sparkle-bridge-ok Sources/UI/Updates/SparkleBridge.swift $'import AppKit\nimport Sparkle'
new_case quartz-in-core;   put quartz-in-core Sources/Core/Bad.swift 'import Quartz'
new_case qlthumb-in-fs;    put qlthumb-in-fs Sources/FSKit/Bad.swift '@preconcurrency import QuickLookThumbnailing'
new_case quicklookui-in-core; put quicklookui-in-core Sources/Core/Model/Bad.swift 'import class QuickLookUI.QLPreviewPanel'
new_case quicklook-ui-ok;  put quicklook-ui-ok Sources/UI/QuickLook/Preview.swift $'import Quartz\nimport QuickLookThumbnailing'
new_case quicklook-platform-ok; put quicklook-platform-ok Sources/Core/Platform/Preview.swift 'import QuickLook'
new_case ql-in-coretests;  put ql-in-coretests Tests/CoreTests/Bad.swift '    let g = QLThumbnailGenerator.shared'
new_case ql-panel-in-bench; put ql-panel-in-bench Tests/BenchTests/Bad.swift '    QLPreviewPanel.shared()?.reloadData()'
new_case ql-uitests-ok;    put ql-uitests-ok Tests/UITests/QuickLookTests.swift $'    _ = QLPreviewPanel.shared()\n    _ = QLThumbnailGenerator.shared'

run_case appkit-in-core 1 appkit-in-core
run_case swiftui-in-fs 1 appkit-in-core
run_case class-import 1 appkit-in-core
run_case fs-imports-core 1 upward-import
run_case core-imports-ui 1 upward-import
run_case ui-fixtures 1 fixtures-in-app
run_case manifest 1 manifest-fixtures
run_case manifest-transitive 1 manifest-fixtures
run_case defaults 1 test-globals
run_case suite 1 test-globals
run_case storage 1 test-globals
run_case general 1 test-globals
run_case harness-general 1 test-globals
run_case trash-in-test 1 system-trash
run_case trash-in-helper 1 system-trash
run_case trash-harness 1 system-trash
run_case users-json 1 users-literal
run_case users-bench 1 users-literal
run_case users-uitest 1 users-literal
run_case users-other-ok 0
run_case platform-ok 0
run_case two-escapes 1 unsafe-escape
run_case sparkle-elsewhere 1 sparkle-confined
run_case sparkle-in-test 1 sparkle-confined
run_case sparkle-bridge-ok 0
run_case quartz-in-core 1 quicklook-in-core
run_case qlthumb-in-fs 1 quicklook-in-core
run_case quicklookui-in-core 1 quicklook-in-core
run_case quicklook-ui-ok 0
run_case quicklook-platform-ok 0
run_case ql-in-coretests 1 quicklook-in-tests
run_case ql-panel-in-bench 1 quicklook-in-tests
run_case ql-uitests-ok 0

if [ "$fails" -gt 0 ]; then echo "test-check-layering: $fails case(s) failed"; exit 1; fi
echo "test-check-layering: all cases passed"
