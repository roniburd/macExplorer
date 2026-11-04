import AppKit
import XCTest
import Core
@testable import UI

/// MacxApplication's scenario-only key delivery (P1-41): when AppKit has no key window (e.g. after a sheet ended
/// while the process was not frontmost), posted keys go to the pinned window: key equivalents first, then keyDown.
@MainActor
final class MacxApplicationTests: XCTestCase {
    private final class Recorder: NSView {
        var downs: [String] = []
        var ups = 0
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) { downs.append(event.characters ?? "") }
        override func keyUp(with event: NSEvent) { ups += 1 }
    }

    private final class Target: NSObject {
        var hits = 0
        @objc func fire(_ sender: Any?) { hits += 1 }
    }

    private func events(_ text: String, window: NSWindow) throws -> [NSEvent] {
        let spec = try XCTUnwrap(KeyChord(parsing: text).flatMap(KeySynth.spec(for:)) ?? KeySynth.typingSpecs(text).first)
        return KeySynth.events(spec, windowNumber: window.windowNumber)
    }

    func testPinnedWindowGetsKeysAndMenuEquivalents() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let recorder = Recorder(frame: NSRect(x: 10, y: 10, width: 200, height: 24))
        window.contentView?.addSubview(recorder)
        XCTAssertTrue(window.makeFirstResponder(recorder))
        XCTAssertFalse(window.isKeyWindow, "the case this covers: AppKit has another (or no) key window")

        let target = Target()
        let menu = NSMenu(title: "m")
        let item = NSMenuItem(title: "K", action: #selector(Target.fire(_:)), keyEquivalent: "k")
        item.keyEquivalentModifierMask = .command
        item.target = target
        menu.addItem(item)

        for event in try events("up", window: window) { MacxApplication.deliver(event, toPinned: window, menu: menu) }
        XCTAssertEqual(recorder.downs.count, 1, "arrow keys reach the first responder")
        recorder.downs = []
        recorder.ups = 0
        for event in try events("q", window: window) { MacxApplication.deliver(event, toPinned: window, menu: menu) }
        XCTAssertEqual(recorder.downs, ["q"])
        XCTAssertEqual(recorder.ups, 1)
        for event in try events("cmd+k", window: window) { MacxApplication.deliver(event, toPinned: window, menu: menu) }
        XCTAssertEqual(target.hits, 1)
        XCTAssertEqual(recorder.downs, ["q"], "a key equivalent does not also reach keyDown")
    }
}
