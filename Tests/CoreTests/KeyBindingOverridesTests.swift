import XCTest
@testable import Core

final class KeyBindingOverridesTests: XCTestCase {
    private func chord(_ text: String) -> KeyChord { KeyChord(parsing: text)! }

    func testMouseButtonBoundsAndText() {
        XCTAssertNil(MouseButton(number: 2))
        XCTAssertNil(MouseButton(number: 9))
        XCTAssertEqual(MouseButton(number: 3)?.description, "mouse4")
        XCTAssertEqual(MouseButton(parsing: "mouse4"), MouseButton(number: 3))
        XCTAssertEqual(MouseButton(parsing: "Mouse9"), MouseButton(number: 8))
        XCTAssertNil(MouseButton(parsing: "mouse3"), "buttonNumber 2 (middle) is not bindable")
        XCTAssertNil(MouseButton(parsing: "mousex"))
        XCTAssertLessThan(MouseButton(number: 3)!, MouseButton(number: 4)!)
    }

    func testKeyChordCodableRoundTripsEveryKeyKind() throws {
        let texts = ["cmd+[", "shift+cmd+n", "opt+cmd+delete", "fn+delete", "shift+fn+delete", "F2", "F20", "opt+left",
                     "return", "enter", "tab", "esc", "space", "ctrl+opt+shift+cmd+up", "cmd++", "x"]
        let chords = texts.map(chord)
        let data = try JSONEncoder().encode(chords)
        XCTAssertEqual(try JSONDecoder().decode([KeyChord].self, from: data), chords)
        XCTAssertThrowsError(try JSONDecoder().decode(KeyChord.self, from: Data(#""cmd+nope""#.utf8)))
    }

    func testOverridesRoundTrip() throws {
        var o = KeyBindingOverrides.empty
        o.commands[.back] = .init(primary: .chord(chord("opt+cmd+b")), alternates: [chord("delete")],
                                  mouse: [MouseButton(number: 5)!])
        o.commands[.duplicate] = .init(primary: .unbound)
        let data = try JSONEncoder().encode(o)
        XCTAssertEqual(try JSONDecoder().decode(KeyBindingOverrides.self, from: data), o)
    }

    func testDecodingDropsBadPiecesOnly() throws {
        let json = #"""
        {"back": {"primary": "cmd+nope", "alternates": ["delete", "zz+q"], "mouse": ["mouse4", "mouse99"]},
         "noSuchCommand": {"primary": "cmd+k"},
         "forward": {"primary": 7, "mouse": ["mouse5"]},
         "duplicate": {"primary": ""}}
        """#
        let o = try JSONDecoder().decode(KeyBindingOverrides.self, from: Data(json.utf8))
        XCTAssertEqual(o.commands[.back], .init(primary: nil, alternates: [chord("delete")], mouse: [MouseButton(number: 3)!]))
        XCTAssertEqual(o.commands[.forward], .init(primary: nil, alternates: nil, mouse: [MouseButton(number: 4)!]))
        XCTAssertEqual(o.commands[.duplicate], .init(primary: .unbound))
        XCTAssertEqual(o.commands.count, 3)
    }

    func testNonObjectFailsToDecode() {
        XCTAssertThrowsError(try JSONDecoder().decode(KeyBindingOverrides.self, from: Data("[1,2]".utf8)))
    }
}
