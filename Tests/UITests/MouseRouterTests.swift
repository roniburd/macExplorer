import XCTest
import AppKit
import CoreGraphics
@testable import UI
import Core

@MainActor
enum MouseEvents {
    /// A real `.otherMouseDown` with `buttonNumber` set (NSEvent.mouseEvent can't set it).
    static func otherDown(_ buttonNumber: Int) -> NSEvent {
        let cg = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: .zero,
                         mouseButton: CGMouseButton(rawValue: UInt32(buttonNumber))!)!
        return NSEvent(cgEvent: cg)!
    }
}

@MainActor
final class MouseRouterTests: XCTestCase {
    func testSyntheticEventCarriesTheButtonNumber() {
        let event = MouseEvents.otherDown(3)
        XCTAssertEqual(event.type, .otherMouseDown)
        XCTAssertEqual(event.buttonNumber, 3)
    }

    func testBackAndForwardButtonsNavigateHistory() async throws {
        let h = try await ShellHarness.make(self)
        try h.dir("A/B")
        let controller = try await h.openWindow("A")
        controller.navigate(to: h.url("A/B"))
        try await h.waitUntil("in B") { controller.session.folder.directory.lastPathComponent == "B" }
        XCTAssertTrue(MouseRouter.handle(MouseEvents.otherDown(3), in: controller.window))
        try await h.waitUntil("back in A") { controller.session.folder.directory.lastPathComponent == "A" }
        XCTAssertTrue(MouseRouter.handle(MouseEvents.otherDown(4), in: controller.window))
        try await h.waitUntil("forward to B") { controller.session.folder.directory.lastPathComponent == "B" }
    }

    func testReboundButtonFollowsActiveBindings() async throws {
        let h = try await ShellHarness.make(self)
        try h.dir("A/B")
        let controller = try await h.openWindow("A/B")
        h.environment.settings.keyBindingOverrides.reassign(.mouse(MouseButton(number: 5)!), to: .up, as: .mouse)
        try await h.waitUntil("bindings applied") { ActiveKeyBindings.current.command(for: MouseButton(number: 5)!) == .up }
        XCTAssertTrue(MouseRouter.handle(MouseEvents.otherDown(5), in: controller.window))
        try await h.waitUntil("up to A") { controller.session.folder.directory.lastPathComponent == "A" }
    }

    func testUnboundButtonAndOtherEventsPassThrough() async throws {
        let h = try await ShellHarness.make(self)
        let controller = try await h.openWindow()
        XCTAssertFalse(MouseRouter.handle(MouseEvents.otherDown(6), in: controller.window), "unbound")
        XCTAssertFalse(MouseRouter.handle(MouseEvents.otherDown(2), in: controller.window), "middle button")
        XCTAssertFalse(MouseRouter.handle(KeyEvents.backspace(), in: controller.window), "not a mouse event")
    }

    func testNonBrowserWindowIsIgnored() throws {
        try ShellHarness.requireWindowServer()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        XCTAssertFalse(MouseRouter.handle(MouseEvents.otherDown(3), in: window))
        XCTAssertFalse(MouseRouter.handle(MouseEvents.otherDown(3), in: nil))
    }

    func testUnavailableCommandIsConsumed() async throws {
        let h = try await ShellHarness.make(self)
        let controller = try await h.openWindow()
        XCTAssertFalse(controller.session.history.canGoBack)
        let before = controller.session.folder.directory
        XCTAssertTrue(MouseRouter.handle(MouseEvents.otherDown(3), in: controller.window))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(controller.session.folder.directory, before)
    }

    func testIgnoredWhileTheWindowHasASheet() async throws {
        let h = try await ShellHarness.make(self)
        try h.dir("A/B")
        let controller = try await h.openWindow("A")
        controller.navigate(to: h.url("A/B"))
        try await h.waitUntil("in B") { controller.session.folder.directory.lastPathComponent == "B" }
        let window = try XCTUnwrap(controller.window)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                             backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        window.beginSheet(sheet, completionHandler: nil)
        defer { window.endSheet(sheet); sheet.orderOut(nil) }
        try await h.waitUntil("sheet attached") { window.attachedSheet === sheet }
        XCTAssertFalse(MouseRouter.handle(MouseEvents.otherDown(3), in: window))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(controller.session.folder.directory.lastPathComponent, "B")
    }
}
