import AppKit
import XCTest
import Core
@testable import UI

final class ScenarioKeySynthTests: XCTestCase {
    private func spec(_ text: String) throws -> SynthKey { try XCTUnwrap(KeyChord(parsing: text).flatMap(KeySynth.spec(for:)), text) }

    func testFunctionAndArrowKeys() throws {
        let f2 = try spec("F2")
        XCTAssertEqual(f2.keyCode, 120)
        XCTAssertEqual(f2.characters, String(UnicodeScalar(UInt32(NSF2FunctionKey))!))
        XCTAssertTrue(f2.flags.contains(.function))
        let up = try spec("cmd+up")
        XCTAssertEqual(up.keyCode, 126)
        XCTAssertEqual(up.flags.intersection([.command, .function, .numericPad]), [.command, .function, .numericPad])
    }

    func testCharacterKeysUseANSIKeyCodesAndBaseCharacters() throws {
        let dot = try spec("cmd+shift+.")
        XCTAssertEqual(dot.keyCode, 47)
        XCTAssertEqual(dot.charactersIgnoringModifiers, ".")
        XCTAssertTrue(dot.flags.contains([.command, .shift]))
        XCTAssertEqual(try spec("opt+d").keyCode, 2)
        XCTAssertEqual(try spec("cmd+[").keyCode, 33)
    }

    func testEditingKeys() throws {
        XCTAssertEqual(try spec("delete").keyCode, 51)
        XCTAssertEqual(try spec("delete").characters, "\u{7F}")
        XCTAssertEqual(try spec("fn+delete").keyCode, 117)
        XCTAssertEqual(try spec("return").characters, "\r")
        XCTAssertEqual(try spec("esc").keyCode, 53)
        XCTAssertEqual(try spec("shift+tab").characters, "\u{19}")
    }

    func testUnsupportedCharacterHasNoSpec() {
        XCTAssertNil(KeySynth.spec(for: KeyChord(.character("é"))))
    }

    func testTypingSpecs() {
        let specs = KeySynth.typingSpecs("Ab/é")
        XCTAssertEqual(specs.map(\.keyCode), [0, 11, 44, 0])
        XCTAssertEqual(specs.map(\.characters), ["A", "b", "/", "é"])
        XCTAssertTrue(specs[0].flags.contains(.shift))
        XCTAssertFalse(specs[1].flags.contains(.shift))
    }

    /// P1-41 deviation: plain NSEvent.keyEvent(...) events never match a "\u{8}" (⌘⌫) menu key equivalent; the
    /// CGEvent-backed events KeySynth posts match it the way the hardware key does.
    @MainActor
    func testEventsMatchBackspaceMenuEquivalentsAndKeepTheWindowNumber() throws {
        _ = NSApplication.shared
        final class Target: NSObject { var hits = 0; @objc func fire(_ sender: Any?) { hits += 1 } }
        let target = Target()
        let menu = NSMenu(title: "m")
        let item = NSMenuItem(title: "Delete Permanently", action: #selector(Target.fire(_:)), keyEquivalent: "\u{8}")
        item.keyEquivalentModifierMask = [.command, .option]
        item.target = target
        menu.addItem(item)
        let events = KeySynth.events(try spec("opt+cmd+delete"), windowNumber: 42)
        XCTAssertEqual(events.map(\.type), [.keyDown, .keyUp])
        let down = try XCTUnwrap(events.first)
        XCTAssertEqual(down.windowNumber, 42)
        XCTAssertEqual(down.keyCode, 51)
        XCTAssertEqual(down.characters, "\u{7F}")
        XCTAssertTrue(down.modifierFlags.contains([.command, .option]))
        XCTAssertTrue(menu.performKeyEquivalent(with: down))
        XCTAssertEqual(target.hits, 1)
        let typed = try XCTUnwrap(KeySynth.events(KeySynth.typingSpecs("é")[0], windowNumber: 42).first)
        XCTAssertEqual(typed.characters, "é")
    }
}
