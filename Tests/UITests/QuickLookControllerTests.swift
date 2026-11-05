// Tests/UITests/QuickLookControllerTests.swift
import XCTest
import AppKit
import Quartz
@testable import UI
import Core
import MacxFS

/// In-memory stand-in for QLPreviewPanel: no panel is ever shown, so no previewer reads a file.
@MainActor
final class FakeQuickLookPanel: QuickLookPanelControlling {
    var isVisible = false
    var reloads = 0
    var shows = 0
    func show() { isVisible = true; shows += 1 }
    func hide() { isVisible = false }
    func reloadData() { reloads += 1 }
}

@MainActor
final class QuickLookControllerTests: XCTestCase {
    private var h: ContentTestHarness!
    private var model: FolderModel!
    private let panel = FakeQuickLookPanel()
    private var controller: QuickLookController!

    override func setUp() async throws {
        h = try await ContentTestHarness.make(self)
        for n in ["a.txt", "b.txt", "c.txt"] { try h.file(n) }
        model = try await h.openFolder()
        controller = QuickLookController(panel: { [panel] in panel })
        controller.bind(model)
    }

    override func tearDown() async throws {
        controller = nil
        model = nil
        h = nil
    }

    func testToggleShowsSelectionAndHides() {
        model.select(.names(["b.txt"]))
        controller.toggle()
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(controller.items.map(\.lastPathComponent), ["b.txt"])
        controller.toggle()
        XCTAssertFalse(panel.isVisible)
    }

    func testItemsFollowDisplayOrder() {
        model.select(.set(IndexSet([2, 0]), cursor: 0))
        controller.toggle()
        XCTAssertEqual(controller.items.map(\.lastPathComponent), ["a.txt", "c.txt"])
    }

    func testNoSelectionDoesNotOpen() {
        model.select(.none)
        controller.toggle()
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(panel.shows, 0)
    }

    func testNoSelectionClosesAnOpenPanel() {
        model.select(.names(["a.txt"]))
        controller.toggle()
        model.select(.none)
        XCTAssertTrue(panel.isVisible)
        controller.toggle()
        XCTAssertFalse(panel.isVisible)
    }

    func testSelectionChangeReloadsVisiblePanelOnly() {
        model.select(.names(["a.txt"]))
        model.select(.names(["b.txt"]))
        XCTAssertEqual(panel.reloads, 0, "hidden panel is not reloaded")
        controller.toggle()
        model.select(.names(["c.txt"]))
        XCTAssertEqual(panel.reloads, 1)
        XCTAssertEqual(controller.items.map(\.lastPathComponent), ["c.txt"])
    }

    func testRebindToAnotherFolderReloadsVisiblePanel() async throws {
        try h.file("sub/z.txt")
        let other = try await h.openFolder("sub")
        model.select(.names(["a.txt"]))
        controller.toggle()
        other.select(.names(["z.txt"]))
        controller.bind(other)
        XCTAssertEqual(controller.items.map(\.lastPathComponent), ["z.txt"])
        XCTAssertEqual(panel.reloads, 1)
        model.select(.names(["b.txt"]))
        XCTAssertEqual(controller.items.map(\.lastPathComponent), ["z.txt"], "the old folder is no longer observed")
    }

    func testArrowsForwardOnlyWithAtMostOneItem() {
        model.select(.names(["a.txt"]))
        controller.toggle()
        var forwarded: [KeyChord] = []
        XCTAssertTrue(controller.handlePanelKey(KeyChord(.down)) { forwarded.append($0) })
        XCTAssertTrue(controller.handlePanelKey(KeyChord(.up, .shift)) { forwarded.append($0) })
        XCTAssertEqual(forwarded, [KeyChord(.down), KeyChord(.up, .shift)])
        XCTAssertFalse(controller.handlePanelKey(KeyChord(.down, .command)) { forwarded.append($0) }, "⌘↓ is not forwarded")
        model.select(.names(["a.txt", "b.txt"]))
        XCTAssertFalse(controller.handlePanelKey(KeyChord(.right)) { forwarded.append($0) }, "panel steps through several items itself")
        XCTAssertFalse(controller.handlePanelKey(KeyChord(.character("x"))) { forwarded.append($0) })
        XCTAssertEqual(forwarded.count, 2)
        XCTAssertTrue(controller.handlePanelKey(KeyChord(.space)) { _ in })
        XCTAssertFalse(panel.isVisible, "Space in the panel closes it")
    }

    func testEscapeHidesAVisiblePanelOnly() {
        XCTAssertFalse(controller.hideIfVisible(), "nothing to close")
        model.select(.names(["a.txt"]))
        controller.toggle()
        XCTAssertTrue(controller.hideIfVisible())
        XCTAssertFalse(panel.isVisible)
    }

    // Review Focus 1
    func testSpaceDuringTypeSelectGoesToTypeSelect() {
        var now = ContinuousClock.now
        let typeSelect = TypeSelect(timeout: .seconds(1), now: { now })
        XCTAssertFalse(typeSelect.isCollecting)
        _ = typeSelect.append("m"); _ = typeSelect.append("y")
        XCTAssertTrue(typeSelect.isCollecting)
        XCTAssertNil(KeyRouter.command(for: KeyChord(.space), focus: .content, returnKey: .open,
                                       typeSelectActive: typeSelect.isCollecting))
        let space = KeyEvents.key(49, " ")
        XCTAssertTrue(TypeSelect.accepts(space, collecting: typeSelect.isCollecting))
        XCTAssertEqual(typeSelect.append(" ").text, "my ")
        XCTAssertEqual(typeSelect.append("f").text, "my f")
        now = now.advanced(by: .milliseconds(1500))
        XCTAssertFalse(typeSelect.isCollecting)
        XCTAssertFalse(TypeSelect.accepts(space, collecting: typeSelect.isCollecting), "a leading space never starts a buffer")
        XCTAssertEqual(KeyRouter.command(for: KeyChord(.space), focus: .content, returnKey: .open,
                                         typeSelectActive: typeSelect.isCollecting), .quickLook)
        XCTAssertEqual(KeyRouter.command(for: KeyChord(.space, .shift), focus: .content, returnKey: .open, typeSelectActive: true),
                       KeyDispatcher(returnKey: .open).command(for: KeyChord(.space, .shift), in: .content),
                       "only plain Space is held back for type-select")
    }

    func testSpaceInTheListTogglesQuickLookUnlessTypeSelectIsCollecting() async throws {
        let window = try await h.openBrowserWindow()
        let fake = FakeQuickLookPanel()
        window.installQuickLook(panel: { fake })
        let content = try h.content(of: window)
        let details = try XCTUnwrap(content.activeList as? DetailsViewController)
        window.session.folder.select(.names(["a.txt"]))
        XCTAssertTrue(details.handleKeyDown(KeyEvents.key(49, " ")))
        XCTAssertTrue(fake.isVisible, "Space opens Quick Look over the selection")
        XCTAssertEqual(window.quickLook.items.map(\.lastPathComponent), ["a.txt"])
        XCTAssertEqual(window.scenarioHooks.quickLookState?().visible, true)
        XCTAssertEqual(window.scenarioHooks.quickLookState?().items, ["a.txt"])
        XCTAssertTrue(details.handleKeyDown(KeyEvents.key(49, " ")))
        XCTAssertFalse(fake.isVisible)

        XCTAssertTrue(details.handleKeyDown(KeyEvents.key(11, "b")))
        XCTAssertTrue(details.typeSelect.isCollecting)
        XCTAssertTrue(details.handleKeyDown(KeyEvents.key(49, " ")), "type-select takes the space")
        XCTAssertFalse(fake.isVisible)
        XCTAssertEqual(details.typeSelect.buffer, "b ")
    }

    func testWindowIsThePanelControllerAndCommandStateReportsVisibility() async throws {
        let window = try await h.openBrowserWindow()
        let fake = FakeQuickLookPanel()
        window.installQuickLook(panel: { fake })
        XCTAssertFalse(FileCommandController.pendingCommands.contains(.quickLook))
        XCTAssertTrue(window.acceptsPreviewPanelControl(nil))
        let content = try h.content(of: window)
        let handler = try XCTUnwrap(content.handler)
        let target = CommandTarget.contentSelection(window.session.folder)
        window.session.folder.select(.none)
        XCTAssertFalse(handler.canPerform(.quickLook, target: target))
        window.session.folder.select(.names(["c.txt"]))
        XCTAssertTrue(handler.canPerform(.quickLook, target: target))
        handler.perform(.quickLook, target: target, sender: nil)
        XCTAssertTrue(fake.isVisible)
        window.session.folder.select(.none)
        XCTAssertTrue(handler.canPerform(.quickLook, target: target), "Space closes an open panel with nothing selected")
        handler.perform(.cancelOperation, target: target, sender: nil)
        XCTAssertFalse(fake.isVisible, "Esc closes Quick Look, as in Finder")
    }

    func testContextMenuHasQuickLookAfterOpenWith() async throws {
        let window = try await h.openBrowserWindow()
        window.installQuickLook(panel: { FakeQuickLookPanel() })
        let content = try h.content(of: window)
        let ids = (content.contextMenu(forRow: 0)?.items ?? []).compactMap { $0.identifier?.rawValue }
        let openWith = try XCTUnwrap(ids.firstIndex(of: "macx.menu.openWith"))
        XCTAssertEqual(ids[openWith + 1], "macx.menu.quickLook")
        let item = content.contextMenu(forRow: 0)?.items.first { $0.identifier?.rawValue == "macx.menu.quickLook" }
        XCTAssertEqual(item?.title, "Quick Look")
    }
}
