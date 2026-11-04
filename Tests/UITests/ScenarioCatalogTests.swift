import XCTest
import Core
@testable import UI

final class ScenarioCatalogTests: XCTestCase {
    static let directory = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Scenarios")

    private func files() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func testEveryScenarioFileDecodesValidatesAndIsNamedAfterItsFile() throws {
        let urls = try files()
        XCTAssertEqual(urls.count, 25)
        for url in urls {
            let file = try ScenarioFile.load(Data(contentsOf: url))
            XCTAssertEqual(file.name, url.deletingPathExtension().lastPathComponent)
            XCTAssertFalse(file.steps.isEmpty, file.name)
        }
    }

    func testSpecSmokeListIsCovered() throws {
        let names = Set(try files().map { $0.deletingPathExtension().lastPathComponent })
        for required in ["navigate-address-bar", "rename-f2", "cut-paste", "drag-move", "right-drag-menu", "conflict-dialog",
                         "properties", "undo-redo", "colliding-keys", "hidden-toggle", "filter-in-folder", "empty-states"] {
            XCTAssertTrue(names.contains(required), required)
        }
    }

    func testKeyNamesMapToTheIntendedKeys() {
        let table: [(String, KeyChord)] = [
            ("cmd+l", KeyChord(.character("l"), .command)), ("F2", KeyChord(.function(2))),
            ("opt+left", KeyChord(.left, .option)), ("cmd+up", KeyChord(.up, .command)),
            ("delete", KeyChord(.backspace)), ("cmd+delete", KeyChord(.backspace, .command)),
            ("opt+cmd+delete", KeyChord(.backspace, [.option, .command])), ("fn+delete", KeyChord(.forwardDelete)),
            ("shift+fn+delete", KeyChord(.forwardDelete, .shift)), ("cmd+shift+.", KeyChord(.character("."), [.command, .shift])),
            ("cmd+[", KeyChord(.character("["), .command)), ("opt+return", KeyChord(.returnKey, .option)),
            ("esc", KeyChord(.escape)), ("return", KeyChord(.returnKey)), ("ctrl+z", KeyChord(.character("z"), .control)),
        ]
        for (text, chord) in table { XCTAssertEqual(KeyChord(parsing: text), chord, text) }
    }
}
