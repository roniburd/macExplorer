import XCTest
import MacxFixtures
@testable import Core

/// P4-01: keymap JSON import/export (Review Focus 3, model half). Files are read and written only in a Sandbox;
/// no open/save panels.
final class KeymapDocumentTests: XCTestCase {
    private func doc(_ bindings: String, base: String = "explorer", version: Int = 1) -> Data {
        Data(#"{"format":"macexplorer-keymap","version":\#(version),"base":"\#(base)","bindings":\#(bindings)}"#.utf8)
    }
    private func k(_ s: String) -> KeyChord { KeyChord(parsing: s)! }
    private func importing(_ data: Data) throws -> (KeyBindingOverrides, [KeymapWarning]) {
        try KeymapDocument.import(data)
    }

    func testExportImportRoundTripThroughASandboxFile() throws {
        let sandbox = try Sandbox(); defer { sandbox.destroy() }
        var o = KeyBindingOverrides.empty
        o.reassign(.key(k("opt+cmd+c")), to: .copyAsPath, as: .primary)
        o.reassign(.key(k("ctrl+r")), to: .refresh, as: .alternate)
        o.reassign(.mouse(MouseButton(number: 5)!), to: .up, as: .mouse)
        o.setPrimary(nil, for: .duplicate)
        let url = try sandbox.createFile("keys.json", contents: KeymapDocument.export(o))
        let (q, warnings) = try importing(Data(contentsOf: url))
        XCTAssertEqual(q, o)
        XCTAssertEqual(warnings, [])
    }

    func testExportOfDefaultsAndPresetsRoundTrips() throws {
        for p in KeymapPreset.allCases {
            let (q, w) = try importing(KeymapDocument.export(p.overrides))
            XCTAssertEqual(q, p.overrides, "\(p)")
            XCTAssertEqual(w, [])
        }
    }

    func testExportContainsOnlyChangesFromTheNearestPresetSorted() throws {
        var o = KeyBindingOverrides.empty
        o.setPrimary(nil, for: .duplicate)
        let json = String(decoding: KeymapDocument.export(o), as: UTF8.self)
        XCTAssertTrue(json.contains(#""format" : "macexplorer-keymap""#), json)
        XCTAssertTrue(json.contains(#""version" : 1"#), json)
        XCTAssertTrue(json.contains(#""base" : "explorer""#), json)
        XCTAssertTrue(json.contains(#""duplicate""#), json)
        XCTAssertTrue(json.contains(#""primary" : null"#), json)
        XCTAssertFalse(json.contains(#""rename""#), json)
        XCTAssertFalse(json.contains(#""alternates""#), "untouched slots are left out: \(json)")

        var f = KeymapPreset.finder.overrides
        f.setPrimary(k("opt+cmd+n"), for: .newWindow)
        let finderJSON = String(decoding: KeymapDocument.export(f), as: UTF8.self)
        XCTAssertTrue(finderJSON.contains(#""base" : "finder""#), finderJSON)
        XCTAssertTrue(finderJSON.contains(#""newWindow""#), finderJSON)
        XCTAssertFalse(finderJSON.contains(#""open""#), "Finder's own bindings come from the base: \(finderJSON)")
        XCTAssertEqual(try importing(KeymapDocument.export(f)).0, f)
        // Keys are sorted, so exports diff cleanly.
        let o2 = KeyBindingOverrides(commands: [.undo: .init(primary: .unbound), .back: .init(primary: .unbound)])
        let s = String(decoding: KeymapDocument.export(o2), as: UTF8.self)
        XCTAssertLessThan(try XCTUnwrap(s.range(of: #""back""#)).lowerBound, try XCTUnwrap(s.range(of: #""undo""#)).lowerBound)
    }

    func testImportOnAFinderBaseAndSlotMerging() throws {
        let (o, w) = try importing(doc(#"{"newWindow":{"primary":"opt+cmd+n"},"refresh":{"alternates":["ctrl+r"]}}"#, base: "finder"))
        XCTAssertEqual(w, [])
        let b = KeyBindings(overrides: o)
        XCTAssertEqual(b.primary(.open), k("cmd+o"), "from the Finder base")
        XCTAssertEqual(b.primary(.newWindow), k("opt+cmd+n"))
        XCTAssertEqual(b.alternates(.newWindow), [])
        XCTAssertNil(b.primary(.refresh), "a slot the file leaves out keeps the base's value")
        XCTAssertEqual(b.alternates(.refresh), [k("ctrl+r")])
        XCTAssertEqual(b.mouse(.back), KeyMap.defaultMouse(.back))
        // "" means unbound too (the Settings storage spelling).
        let (u, _) = try importing(doc(#"{"duplicate":{"primary":""}}"#))
        XCTAssertNil(KeyBindings(overrides: u).primary(.duplicate))
    }

    /// Review Focus 3: conflicts and reserved chords are rejected with the offending pairs; unknown commands are
    /// skipped with a warning.
    func testImportRejectsConflictsAndReservedSkipsUnknown() throws {
        XCTAssertThrowsError(try importing(doc(#"{"newFolder":{"primary":"cmd+l"}}"#))) {
            XCTAssertEqual($0 as? KeymapImportError,
                           .issues([.conflict(trigger: .key(self.k("cmd+l")), commands: [.focusAddressBar, .newFolder])]))
        }
        XCTAssertThrowsError(try importing(doc(#"{"refresh":{"primary":"cmd+q"}}"#))) {
            XCTAssertEqual($0 as? KeymapImportError, .issues([.reserved(chord: self.k("cmd+q"), command: .refresh)]))
        }
        XCTAssertThrowsError(try importing(doc(#"{"refresh":{"alternates":["ctrl+up"]}}"#))) {
            XCTAssertEqual($0 as? KeymapImportError, .issues([.reserved(chord: self.k("ctrl+up"), command: .refresh)]))
        }
        XCTAssertThrowsError(try importing(doc(#"{"refresh":{"primary":"cmd+tab"}}"#))) {
            XCTAssertEqual($0 as? KeymapImportError, .issues([.reserved(chord: self.k("cmd+tab"), command: .refresh)]))
        }
        // An alternate that another command holds, and a shared mouse button.
        XCTAssertThrowsError(try importing(doc(#"{"refresh":{"alternates":["F3"]},"up":{"mouse":["mouse4"]}}"#))) {
            XCTAssertEqual($0 as? KeymapImportError, .issues([
                .conflict(trigger: .key(self.k("F3")), commands: [.focusSearch, .refresh]),
                .conflict(trigger: .mouse(MouseButton(number: 3)!), commands: [.back, .up]),
            ]))
        }
        // Several problems are all listed: conflicts (by trigger), then per-command problems (by command).
        XCTAssertThrowsError(try importing(doc(#"{"undo":{"primary":"cmd+m"},"newFolder":{"primary":"cmd+l"},"copy":{"primary":"a"}}"#))) {
            XCTAssertEqual($0 as? KeymapImportError, .issues([
                .conflict(trigger: .key(self.k("cmd+l")), commands: [.focusAddressBar, .newFolder]),
                .notAPrimary(chord: self.k("a"), command: .copy),
                .reserved(chord: self.k("cmd+m"), command: .undo),
            ]))
        }
        let (p, w) = try importing(doc(#"{"teleport":{"primary":"opt+cmd+t"},"cancelOperation":{"alternates":["F9"]}}"#))
        XCTAssertEqual(p, .empty)
        XCTAssertEqual(w, [.fixedCommand(.cancelOperation), .unknownCommand("teleport")], "in name order")
    }

    func testUnshippedCommandsAreSkippedLikeUnknownOnes() throws {
        let unshipped = Command.allCases.filter { !CommandAvailability.isShipped($0) }
        guard let c = unshipped.first else { return }
        let (p, w) = try importing(doc(#"{"\#(c.rawValue)":{"primary":"opt+cmd+t"}}"#))
        XCTAssertEqual(p, .empty)
        XCTAssertEqual(w, [.unknownCommand(c.rawValue)])
    }

    /// Review Focus 3: a text-editing primary is accepted, and marked colliding (disabled while a field editor
    /// has focus, so the key reaches the text).
    func testTextEditingPrimaryIsAcceptedAndMarkedColliding() throws {
        let (p, _) = try importing(doc(#"{"newFolder":{"primary":"cmd+shift+left"}}"#))
        let b = KeyBindings(overrides: p)
        XCTAssertEqual(b.primary(.newFolder), k("cmd+shift+left"))
        XCTAssertTrue(b.collidesWithTextEditing.contains(.newFolder))
        XCTAssertFalse(CommandAvailability.isEnabled(.newFolder, focus: .fieldEditor, state: CommandState(),
                                                     collidesWithTextEditing: b.collidesWithTextEditing))
    }

    func testImportErrors() {
        func expect(_ data: Data, _ error: KeymapImportError, line: UInt = #line) {
            XCTAssertThrowsError(try importing(data), line: line) { XCTAssertEqual($0 as? KeymapImportError, error, line: line) }
        }
        expect(Data("[]".utf8), .notAKeymap)
        expect(Data("not json".utf8), .notAKeymap)
        expect(Data(#"{"format":"something-else","version":1,"base":"explorer","bindings":{}}"#.utf8), .notAKeymap)
        expect(Data(#"{"format":"macexplorer-keymap","version":1,"base":"explorer","bindings":[]}"#.utf8), .notAKeymap)
        expect(doc("{}", version: 2), .unsupportedVersion(2))
        expect(doc("{}", base: "vim"), .unknownBase("vim"))
        expect(doc(#"{"refresh":{"primary":"hyper+r"}}"#), .invalidChord(command: "refresh", text: "hyper+r"))
        expect(doc(#"{"refresh":{"alternates":["F99"]}}"#), .invalidChord(command: "refresh", text: "F99"))
        expect(doc(#"{"refresh":{"mouse":["mouse3"]}}"#), .invalidChord(command: "refresh", text: "mouse3"))
        expect(doc(#"{"refresh":5}"#), .invalidChord(command: "refresh", text: "5"))
        expect(doc(#"{"refresh":{"primary":7}}"#), .invalidChord(command: "refresh", text: "7"))
    }
}
