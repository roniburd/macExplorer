import XCTest
import AppKit
@testable import UI
import Core
import MacxFS

@MainActor
private final class RecordingHandler: CommandHandler {
    var performed: [Command] = []
    var enabled: Set<Command> = Set(Command.allCases)
    func canPerform(_ command: Command, target: CommandTarget) -> Bool { enabled.contains(command) }
    func perform(_ command: Command, target: CommandTarget, sender: Any?) { performed.append(command) }
}

@MainActor
private final class TestPane: CommandHandlingViewController {
    var target: CommandTarget? = .folder(URL(filePath: "/tmp/macx-tests-pane", directoryHint: .isDirectory))
    override var focusContext: FocusContext { .content }
    override var commandTarget: CommandTarget? { target }
    override func loadView() { view = NSView() }
}

@MainActor
final class CommandActionsTests: XCTestCase {
    func testEveryCommandHasAResponderMethod() {
        let pane = TestPane()
        for command in Command.allCases where !command.isWindowTabCommand {
            XCTAssertTrue(pane.responds(to: Selector(command.selectorName)), "missing @objc \(command.selectorName)")
        }
    }

    func testPanesNeverInterceptNSWindowTabActions() {
        let pane = TestPane()
        for command in Command.windowTabCommands {
            XCTAssertFalse(pane.responds(to: Selector(command.selectorName)), "\(command.selectorName) belongs to NSWindow")
        }
    }

    func testEachActionPerformsItsCommandOnTheTarget() {
        let pane = TestPane()
        let handler = RecordingHandler()
        pane.handler = handler
        let paneCommands = Command.allCases.filter { !$0.isWindowTabCommand }
        for command in paneCommands {
            _ = pane.perform(Selector(command.selectorName), with: nil)
        }
        XCTAssertEqual(handler.performed, paneCommands)
    }

    func testActionsWithoutHandlerOrTargetDoNothing() {
        let pane = TestPane()
        _ = pane.perform(Selector(Command.moveToTrash.selectorName), with: nil)   // no handler: no crash
        let handler = RecordingHandler()
        pane.handler = handler
        pane.target = nil
        _ = pane.perform(Selector(Command.moveToTrash.selectorName), with: nil)
        XCTAssertEqual(handler.performed, [])
    }

    func testValidateMenuItemAsksTheHandler() {
        let pane = TestPane()
        let item = NSMenuItem(title: "Trash", action: Selector(Command.moveToTrash.selectorName), keyEquivalent: "")
        XCTAssertFalse(pane.validateMenuItem(item), "no handler")
        let handler = RecordingHandler()
        pane.handler = handler
        XCTAssertTrue(pane.validateMenuItem(item))
        handler.enabled.remove(.moveToTrash)
        XCTAssertFalse(pane.validateMenuItem(item))
        pane.target = nil
        handler.enabled.insert(.moveToTrash)
        XCTAssertFalse(pane.validateMenuItem(item), "no target")
        pane.target = .folder(URL(filePath: "/tmp/macx-tests-pane", directoryHint: .isDirectory))
        let foreign = NSMenuItem(title: "x", action: #selector(NSText.selectAll(_:)), keyEquivalent: "")
        XCTAssertTrue(pane.validateMenuItem(foreign), "selectAll: is a Command (selectAll)")
        let unknown = NSMenuItem(title: "x", action: NSSelectorFromString("macx_noSuchCommand:"), keyEquivalent: "")
        XCTAssertFalse(pane.validateMenuItem(unknown))
    }

    func testValidateMenuItemDisablesCollidingCommandsWhileAFieldEditorIsActive() throws {
        try ShellHarness.requireWindowServer()
        let pane = TestPane()
        pane.handler = RecordingHandler()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentViewController = pane
        let field = NSTextField(string: "name")
        pane.view.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        let trash = NSMenuItem(title: "", action: Selector(Command.moveToTrash.selectorName), keyEquivalent: "")
        let newFolder = NSMenuItem(title: "", action: Selector(Command.newFolder.selectorName), keyEquivalent: "")
        XCTAssertFalse(pane.validateMenuItem(trash), "⌘⌫ belongs to the text field")
        XCTAssertTrue(pane.validateMenuItem(newFolder))
        window.makeFirstResponder(pane.view)
        XCTAssertTrue(pane.validateMenuItem(trash))
    }

    func testCommandLookupBySelector() {
        for command in Command.allCases {
            XCTAssertEqual(MenuValidation.command(for: Selector(command.selectorName)), command)
        }
        XCTAssertNil(MenuValidation.command(for: nil))
        XCTAssertNil(MenuValidation.command(for: NSSelectorFromString("terminate:")))
    }
}
