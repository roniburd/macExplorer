import AppKit
import XCTest
import Core
@testable import UI

@MainActor
final class FieldEditorKeyRoutingTests: XCTestCase {
    private func event(_ text: String) throws -> NSEvent {
        let chord = try XCTUnwrap(KeyChord(parsing: text))
        let spec = try XCTUnwrap(KeySynth.spec(for: chord))
        return try XCTUnwrap(KeySynth.events(spec, windowNumber: 0).first)
    }

    func testOnlyCollidingPrimariesAreRouted() throws {
        for text in ["cmd+up", "cmd+down", "cmd+delete", "opt+cmd+delete", "cmd+[", "cmd+]", "F2", "cmd+d"] {
            XCTAssertNotNil(FieldEditorKeyRouting.collidingCommand(for: try event(text)), text)
        }
        for text in ["cmd+l", "cmd+c", "cmd+v", "cmd+z", "cmd+left", "left", "a", "cmd+shift+."] {
            XCTAssertNil(FieldEditorKeyRouting.collidingCommand(for: try event(text)), text)
        }
    }

    /// Records keyDowns; the text system's own handling needs a key window, which tests don't have reliably.
    private final class RecordingEditor: NSTextView {
        var keys: [UInt16] = []
        override func keyDown(with event: NSEvent) { keys.append(event.keyCode) }
    }

    func testCollidingKeyGoesToTheFieldEditorInsteadOfTheMenu() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let editor = RecordingEditor(frame: NSRect(x: 10, y: 10, width: 200, height: 24))
        window.contentView?.addSubview(editor)
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertFalse(FieldEditorKeyRouting.route(try event("cmd+up"), in: window), "not a field editor")
        editor.isFieldEditor = true
        XCTAssertFalse(FieldEditorKeyRouting.route(try event("cmd+l"), in: window), "not a colliding key")
        XCTAssertTrue(FieldEditorKeyRouting.route(try event("cmd+up"), in: window))
        XCTAssertTrue(FieldEditorKeyRouting.route(try event("opt+cmd+delete"), in: window))
        XCTAssertEqual(editor.keys, [126, 51])
        XCTAssertFalse(FieldEditorKeyRouting.route(try event("cmd+up"), in: nil))
    }
}
