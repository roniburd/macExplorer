import XCTest
@testable import Core

final class KeyMapTests: XCTestCase {
    private func chord(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> KeyChord {
        guard let c = KeyChord(parsing: text) else {
            XCTFail("cannot parse '\(text)'", file: file, line: line)
            return KeyChord(.escape)
        }
        return c
    }

    // MARK: Command

    func testStandardSelectorNames() {
        XCTAssertEqual(Command.cut.selectorName, "cut:")
        XCTAssertEqual(Command.copy.selectorName, "copy:")
        XCTAssertEqual(Command.paste.selectorName, "paste:")
        XCTAssertEqual(Command.selectAll.selectorName, "selectAll:")
        XCTAssertEqual(Command.undo.selectorName, "undo:")
        XCTAssertEqual(Command.redo.selectorName, "redo:")
        XCTAssertEqual(Command.cancelOperation.selectorName, "cancelOperation:")
    }

    func testCustomSelectorNamesArePrefixed() {
        XCTAssertEqual(Command.moveToTrash.selectorName, "macx_moveToTrash:")
        XCTAssertEqual(Command.open.selectorName, "macx_open:")
        XCTAssertEqual(Command.moveItemHere.selectorName, "macx_moveItemHere:")
        let standard: Set<Command> = [.cut, .copy, .paste, .selectAll, .undo, .redo, .cancelOperation]
        for c in Command.allCases where !standard.contains(c) {
            XCTAssertEqual(c.selectorName, "macx_\(c.rawValue):", "\(c)")
        }
    }

    func testSelectorNamesAreUnique() {
        let names = Command.allCases.map(\.selectorName)
        XCTAssertEqual(Set(names).count, names.count)
    }

    func testCommandCodableRoundTrip() throws {
        let data = try JSONEncoder().encode([Command.moveToTrash, .sortByKind])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"["moveToTrash","sortByKind"]"#)
        XCTAssertEqual(try JSONDecoder().decode([Command].self, from: data), [.moveToTrash, .sortByKind])
    }

    // MARK: KeyChord parsing

    func testParsesScenarioKeyNames() {
        let table: [(String, KeyChord)] = [
            ("cmd+l", KeyChord(.character("l"), .command)), ("F2", KeyChord(.function(2))),
            ("opt+left", KeyChord(.left, .option)), ("cmd+up", KeyChord(.up, .command)),
            ("delete", KeyChord(.backspace)), ("cmd+delete", KeyChord(.backspace, .command)),
            ("opt+cmd+delete", KeyChord(.backspace, [.option, .command])), ("fn+delete", KeyChord(.forwardDelete)),
            ("shift+fn+delete", KeyChord(.forwardDelete, .shift)), ("cmd+shift+.", KeyChord(.character("."), [.command, .shift])),
            ("cmd+[", KeyChord(.character("["), .command)), ("opt+return", KeyChord(.returnKey, .option)),
            ("esc", KeyChord(.escape)), ("return", KeyChord(.returnKey)), ("ctrl+z", KeyChord(.character("z"), .control)),
            ("tab", KeyChord(.tab)), ("F4", KeyChord(.function(4))), ("F5", KeyChord(.function(5))),
            ("up", KeyChord(.up)), ("down", KeyChord(.down)), ("left", KeyChord(.left)), ("right", KeyChord(.right)),
            ("cmd+]", KeyChord(.character("]"), .command)), ("opt+right", KeyChord(.right, .option)),
            ("opt+up", KeyChord(.up, .option)), ("opt+d", KeyChord(.character("d"), .option)),
            ("shift+right", KeyChord(.right, .shift)), ("cmd+shift+z", KeyChord(.character("z"), [.command, .shift])),
            ("cmd+shift+n", KeyChord(.character("n"), [.command, .shift])), ("cmd+shift+r", KeyChord(.character("r"), [.command, .shift])),
            ("cmd+down", KeyChord(.down, .command)), ("ctrl+x", KeyChord(.character("x"), .control)),
            ("ctrl+v", KeyChord(.character("v"), .control)), ("cmd+y", KeyChord(.character("y"), .command)),
        ]
        for (text, expected) in table { XCTAssertEqual(KeyChord(parsing: text), expected, text) }
    }

    func testParsingSynonymsAndCase() {
        XCTAssertEqual(KeyChord(parsing: "Command+Shift+N"), KeyChord(.character("n"), [.command, .shift]))
        XCTAssertEqual(KeyChord(parsing: "alt+option+opt+d"), KeyChord(.character("d"), .option))
        XCTAssertEqual(KeyChord(parsing: "control+c"), KeyChord(.character("c"), .control))
        XCTAssertEqual(KeyChord(parsing: "escape"), KeyChord(.escape))
        XCTAssertEqual(KeyChord(parsing: "f12"), KeyChord(.function(12)))
        XCTAssertEqual(KeyChord(parsing: "F20"), KeyChord(.function(20)))
        XCTAssertEqual(KeyChord(parsing: "backspace"), KeyChord(.backspace))
        XCTAssertEqual(KeyChord(parsing: "cmd+backspace"), KeyChord(.backspace, .command))
        XCTAssertEqual(KeyChord(parsing: "del"), KeyChord(.forwardDelete))
        XCTAssertEqual(KeyChord(parsing: "space"), KeyChord(.space))
        XCTAssertEqual(KeyChord(parsing: "enter"), KeyChord(.enter))
        XCTAssertEqual(KeyChord(parsing: "cmd+A"), KeyChord(.character("a"), .command), "letters are lowercased")
        XCTAssertEqual(KeyChord(parsing: "cmd++"), KeyChord(.character("+"), .command))
        XCTAssertEqual(KeyChord(parsing: "+"), KeyChord(.character("+")))
        XCTAssertEqual(KeyChord(parsing: "fn+F2"), KeyChord(.function(2)), "fn is implied for F-keys")
        XCTAssertEqual(KeyChord(parsing: "cmd+1"), KeyChord(.character("1"), .command))
    }

    func testParsingRejectsGarbage() {
        for bad in ["", "cmd+", "hyper+q", "cmd+shift", "foo", "F0", "F21", "cmd++shift+x", "fn+a", "fn+left", "+cmd"] {
            XCTAssertNil(KeyChord(parsing: bad), bad)
        }
    }

    func testDescriptionRoundTripsThroughParsing() {
        var chords: [KeyChord] = []
        for c in Command.allCases {
            if let p = KeyMap.primary(c) { chords.append(p) }
            chords += KeyMap.alternates(c)
        }
        chords += [KeyChord(.character("+"), .command), KeyChord(.space), KeyChord(.enter), KeyChord(.function(20)),
                   KeyChord(.forwardDelete, [.shift, .control])]
        for c in chords { XCTAssertEqual(KeyChord(parsing: c.description), c, c.description) }
    }

    func testDescriptionIsCanonical() {
        XCTAssertEqual(KeyChord(.backspace, [.command, .option]).description, "opt+cmd+delete")
        XCTAssertEqual(KeyChord(.forwardDelete, .shift).description, "shift+fn+delete")
        XCTAssertEqual(KeyChord(.character("n"), [.shift, .command]).description, "shift+cmd+n")
        XCTAssertEqual(KeyChord(.function(2)).description, "F2")
        XCTAssertEqual(KeyChord(.character("c"), .control).description, "ctrl+c")
    }

    // MARK: KeyMap primaries (§5.6)

    func testPrimariesMatchSpecTable() {
        let expected: [Command: String] = [
            .open: "cmd+down", .rename: "F2", .moveToTrash: "cmd+delete", .deletePermanently: "opt+cmd+delete",
            .cut: "cmd+x", .copy: "cmd+c", .paste: "cmd+v", .moveItemHere: "opt+cmd+v",
            .undo: "cmd+z", .redo: "cmd+shift+z", .back: "cmd+[", .forward: "cmd+]", .up: "cmd+up",
            .focusAddressBar: "cmd+l", .focusSearch: "cmd+f", .newFolder: "cmd+shift+n", .newWindow: "cmd+n",
            .closeWindow: "cmd+w", .properties: "cmd+i", .refresh: "cmd+r", .copyAsPath: "cmd+shift+c",
            .toggleHidden: "cmd+shift+.", .selectAll: "cmd+a", .duplicate: "cmd+d", .eject: "cmd+e",
        ]
        for c in Command.allCases {
            if let text = expected[c] {
                XCTAssertEqual(KeyMap.primary(c), chord(text), "\(c)")
            } else {
                XCTAssertNil(KeyMap.primary(c), "\(c) has no primary in §5.6")
            }
        }
    }

    func testPrimariesAreUnique() {
        var seen: [KeyChord: Command] = [:]
        for c in Command.allCases {
            guard let k = KeyMap.primary(c) else { continue }
            XCTAssertNil(seen[k], "\(k) bound to both \(seen[k].map { "\($0)" } ?? "") and \(c)")
            seen[k] = c
        }
    }

    func testPrimariesAvoidLaterPhaseChords() {
        let reserved = ["cmd+t", "cmd+1", "cmd+2", "cmd+3", "ctrl+tab", "opt+p", "cmd+opt+r"].map { chord($0) }
        for c in Command.allCases {
            if let p = KeyMap.primary(c) { XCTAssertFalse(reserved.contains(p), "\(c) uses \(p)") }
        }
    }

    // MARK: Alternates

    func testAlternatesMatchSpecTable() {
        let expected: [Command: [String]] = [
            .open: ["return"], .rename: ["cmd+shift+r"], .moveToTrash: ["fn+delete"], .deletePermanently: ["shift+fn+delete"],
            .cut: ["ctrl+x"], .copy: ["ctrl+c"], .paste: ["ctrl+v"], .undo: ["ctrl+z"], .redo: ["cmd+y"],
            .back: ["delete", "opt+left"], .forward: ["opt+right"], .up: ["opt+up"], .focusAddressBar: ["opt+d", "F4"],
            .focusSearch: ["F3"], .properties: ["opt+return"], .refresh: ["F5"], .selectAll: ["ctrl+a"],
            .cycleFocusForward: ["tab"], .cycleFocusBackward: ["shift+tab"], .cancelOperation: ["esc"],
        ]
        for c in Command.allCases {
            XCTAssertEqual(KeyMap.alternates(c), (expected[c] ?? []).map { chord($0) }, "\(c)")
        }
    }

    func testAlternatesAreUniqueAndNeverPrimaries() {
        let primaries = Set(Command.allCases.compactMap { KeyMap.primary($0) })
        var seen: [KeyChord: Command] = [:]
        for c in Command.allCases {
            for k in KeyMap.alternates(c) {
                XCTAssertNil(seen[k], "\(k) is an alternate of \(seen[k].map { "\($0)" } ?? "") and \(c)")
                XCTAssertFalse(primaries.contains(k), "\(k) is both a primary and an alternate")
                seen[k] = c
            }
        }
    }

    func testEveryFunctionKeyCommandHasANonFunctionKeyBinding() {
        for c in Command.allCases {
            let all = [KeyMap.primary(c)].compactMap { $0 } + KeyMap.alternates(c)
            let usesF = all.contains { if case .function = $0.key { true } else { false } }
            guard usesF else { continue }
            XCTAssertTrue(all.contains { if case .function = $0.key { false } else { true } }, "\(c)")
        }
    }

    func testCollidingPrimaries() {
        XCTAssertEqual(KeyMap.collidesWithTextEditing,
                       [.open, .up, .moveToTrash, .deletePermanently, .back, .forward, .rename, .duplicate])
    }

    // MARK: KeyDispatcher

    func testDispatchesAlternatesInContent() {
        let d = KeyDispatcher(returnKey: .open)
        let table: [(String, Command)] = [
            ("return", .open), ("opt+return", .properties), ("fn+delete", .moveToTrash), ("shift+fn+delete", .deletePermanently),
            ("ctrl+x", .cut), ("ctrl+c", .copy), ("ctrl+v", .paste), ("ctrl+z", .undo), ("cmd+y", .redo), ("ctrl+a", .selectAll),
            ("delete", .back), ("opt+left", .back), ("opt+right", .forward), ("opt+up", .up), ("opt+d", .focusAddressBar),
            ("F4", .focusAddressBar), ("F3", .focusSearch), ("F5", .refresh), ("cmd+shift+r", .rename),
            ("tab", .cycleFocusForward), ("shift+tab", .cycleFocusBackward), ("esc", .cancelOperation),
        ]
        for (text, command) in table { XCTAssertEqual(d.command(for: chord(text), in: .content), command, text) }
    }

    func testPrimariesAreNotDispatched() {
        let d = KeyDispatcher(returnKey: .open)
        for c in Command.allCases {
            guard let p = KeyMap.primary(c) else { continue }
            XCTAssertNil(d.command(for: p, in: .content), "\(p) belongs to the menu")
        }
        XCTAssertNil(d.command(for: chord("x"), in: .content), "plain letters are type-select")
        XCTAssertNil(d.command(for: chord("space"), in: .content))
    }

    func testReturnKeyBehaviour() {
        XCTAssertEqual(KeyDispatcher(returnKey: .open).command(for: chord("return"), in: .content), .open)
        XCTAssertEqual(KeyDispatcher(returnKey: .rename).command(for: chord("return"), in: .content), .rename)
        XCTAssertEqual(KeyDispatcher(returnKey: .rename).command(for: chord("opt+return"), in: .content), .properties)
        for focus: FocusContext in [.sidebarFavorites, .sidebarLocations, .sidebarFolders, .sidebarVolumeRoot] {
            XCTAssertEqual(KeyDispatcher(returnKey: .rename).command(for: chord("return"), in: focus), .open,
                           "Return navigates in the sidebar (\(focus))")
        }
    }

    func testTextFocusNeverDispatches() {
        for returnKey: ReturnKeyBehavior in [.open, .rename] {
            let d = KeyDispatcher(returnKey: returnKey)
            for c in Command.allCases {
                for k in KeyMap.alternates(c) + ["return", "tab", "esc"].map({ chord($0) }) {
                    XCTAssertNil(d.command(for: k, in: .fieldEditor), "\(k)")
                    XCTAssertNil(d.command(for: k, in: .addressBar), "\(k)")
                }
            }
        }
    }

    func testSidebarRemaps() {
        let d = KeyDispatcher(returnKey: .open)
        XCTAssertEqual(d.command(for: chord("fn+delete"), in: .sidebarFavorites), .removeFromFavorites)
        XCTAssertEqual(d.command(for: chord("fn+delete"), in: .sidebarFolders), .moveToTrash)
        XCTAssertEqual(d.command(for: chord("fn+delete"), in: .sidebarLocations), .moveToTrash, "disabled, not remapped")
        XCTAssertEqual(d.command(for: chord("ctrl+c"), in: .sidebarLocations), .copy)
        XCTAssertEqual(d.command(for: chord("opt+return"), in: .sidebarLocations), .properties)
    }
}
