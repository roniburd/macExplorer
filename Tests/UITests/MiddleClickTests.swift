import XCTest
import AppKit
@testable import UI
@testable import Core
import MacxFS
import MacxFixtures

/// P2-06: open in a new tab by middle-click, ⌘-click (sidebar/tree), Open in New Tab and a drop on the New Tab
/// toolbar button. Every folder lives in a harness sandbox (`macx-tests-<UUID>`).
@MainActor
final class MiddleClickTests: XCTestCase {
    // MARK: routing rules

    func testGestureRules() {
        XCTAssertTrue(MiddleClickRouter.shouldOpenTab(.middleClick, in: .content))
        XCTAssertFalse(MiddleClickRouter.shouldOpenTab(.commandClick, in: .content), "⌘-click toggles selection in content")
        for f in [FocusContext.sidebarFavorites, .sidebarLocations, .sidebarFolders, .sidebarVolumeRoot] {
            XCTAssertTrue(MiddleClickRouter.shouldOpenTab(.middleClick, in: f))
            XCTAssertTrue(MiddleClickRouter.shouldOpenTab(.commandClick, in: f))
        }
        XCTAssertFalse(MiddleClickRouter.shouldOpenTab(.middleClick, in: .fieldEditor))
        XCTAssertFalse(MiddleClickRouter.shouldOpenTab(.middleClick, in: .addressBar))
    }

    func testMiddleClickNeedsPressAndReleaseOnTheSameRow() {
        var tracker = MiddleClickTracker()
        tracker.mouseDown(row: 3)
        XCTAssertEqual(tracker.mouseUp(row: 3), 3)
        XCTAssertNil(tracker.mouseUp(row: 3), "one release per press")
        tracker.mouseDown(row: 3)
        XCTAssertNil(tracker.mouseUp(row: 4), "released over another row")
        tracker.mouseDown(row: nil)
        XCTAssertNil(tracker.mouseUp(row: nil), "empty space")
        tracker.mouseDown(row: 1)
        XCTAssertNil(tracker.mouseUp(row: nil))
    }

    func testFolderTargetByKind() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.dir("A"); try h.file("f.txt")
        try h.dir("X.app/Contents")
        try h.sandbox.createSymlink("files/L", target: "A")
        let model = try await h.openFolder()
        func target(_ name: String) -> URL? { MiddleClickRouter.folderTarget(row: model.row(named: name)!, in: model) }
        XCTAssertEqual(target("A")?.lastPathComponent, "A")
        XCTAssertNil(target("f.txt"))
        XCTAssertNil(target("X.app"), "applications launch, they never open as tabs")
        XCTAssertEqual(target("L")?.lastPathComponent, "L", "links are candidates; OpenPlanner resolves them")
        XCTAssertNil(MiddleClickRouter.folderTarget(row: -1, in: model))
        XCTAssertNil(MiddleClickRouter.folderTarget(row: model.rowCount, in: model))
    }

    func testTabDropPolicyIsInMemoryThenConfirmedOnALane() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.dir("A"); try h.file("f.txt"); try h.dir("P.app/Contents")
        let dir = URL(filePath: h.url("A").path(percentEncoded: false), directoryHint: .isDirectory)
        let fakeDir = URL(filePath: h.url("f.txt").path(percentEncoded: false), directoryHint: .isDirectory) // lies
        let package = URL(filePath: h.url("P.app").path(percentEncoded: false), directoryHint: .isDirectory)
        let missing = URL(filePath: h.url("gone").path(percentEncoded: false), directoryHint: .isDirectory)
        let file = URL(filePath: h.url("f.txt").path(percentEncoded: false), directoryHint: .notDirectory)
        XCTAssertEqual(TabDropPolicy.candidateFolders([dir, file, fakeDir]), [dir, fakeDir])
        let env = h.environment
        let confirmed = await TabDropPolicy.confirmFolders([dir, fakeDir, package, missing], lanes: env.lanes, volumes: env.volumes)
        XCTAssertEqual(confirmed.map(\.lastPathComponent), ["A"], "files, packages and missing paths never open as tabs")
    }

    // MARK: opening tabs

    @MainActor
    private struct World {
        let h: ShellHarness
        let host: BrowserWindowController
        let commands: FileCommandController
        let prompts: ScriptedCommandPrompts
        var tabs: [String] { host.probeTabFolderURLs.map { $0.standardizedFileURL.lastPathComponent } }
        var selectedTab: Int { host.probeSelectedTabIndex }
    }

    private func world(_ setup: (ShellHarness) throws -> Void) async throws -> World {
        let h = try await ShellHarness.make(self)
        try setup(h)
        let host = try await h.openWindow()
        let commands = try XCTUnwrap(host.contentPane?.handler as? FileCommandController)
        let prompts = ScriptedCommandPrompts()
        commands.prompts = prompts
        return World(h: h, host: host, commands: commands, prompts: prompts)
    }

    private func row(_ w: World, _ name: String) throws -> Int { try XCTUnwrap(w.host.session.folder.row(named: name)) }

    func testMiddleClickOnAContentFolderOpensABackgroundTabAndKeepsTheSelection() async throws {
        let w = try await world { try $0.dir("A"); try $0.file("f.txt") }
        let folder = w.host.session.folder
        folder.select(.names(["f.txt"]))
        let details = try XCTUnwrap(w.host.contentViewController?.firstDescendant(of: DetailsViewController.self))
        details.onNewTabGesture?(.middleClick, try row(w, "A"))
        try await w.h.waitUntil("background tab") { w.tabs.count == 2 }
        XCTAssertEqual(w.tabs.last, "A")
        XCTAssertEqual(w.selectedTab, 0, "middle-click opens a background tab")
        XCTAssertEqual(w.host.probeSelectedNames, ["f.txt"], "the selection is unchanged")
        details.onNewTabGesture?(.middleClick, try row(w, "f.txt"))
        details.onNewTabGesture?(.commandClick, try row(w, "A"))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(w.tabs.count, 2, "a file never opens; ⌘-click in content is a selection toggle")
    }

    func testMiddleClickRoutesThroughTheListViews() async throws {
        let w = try await world { try $0.dir("A") }
        let details = try XCTUnwrap(w.host.contentViewController?.firstDescendant(of: DetailsViewController.self))
        let table = details.tableView
        table.layoutSubtreeIfNeeded()
        let rect = table.rect(ofRow: try row(w, "A"))
        let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        var seen: [(NewTabGesture, Int)] = []
        let original = details.onNewTabGesture
        details.onNewTabGesture = { seen.append(($0, $1)); original?($0, $1) }
        let elsewhere = table.convert(NSPoint(x: rect.midX, y: rect.maxY + 200), to: nil)
        details.handleMiddleMouse(at: point, down: true)
        details.handleMiddleMouse(at: elsewhere, down: false)
        XCTAssertTrue(seen.isEmpty, "released away from the row")
        details.handleMiddleMouse(at: point, down: true)
        details.handleMiddleMouse(at: point, down: false)
        XCTAssertEqual(seen.map(\.1), [try row(w, "A")])
        XCTAssertEqual(seen.first?.0, .middleClick)
        try await w.h.waitUntil("background tab") { w.tabs == ["files", "A"] }
    }

    func testMiddleClickRoutesThroughTheIconsGrid() async throws {
        let w = try await world { try $0.dir("A"); try $0.file("f.txt") }
        let content = try XCTUnwrap(w.host.contentPane as? ContentViewController)
        content.setViewMode(.icons)
        let icons = try XCTUnwrap(content.icons)
        icons.collectionView.layoutSubtreeIfNeeded()
        func point(_ name: String) throws -> NSPoint {
            let frame = icons.layout.frame(forItem: try row(w, name))
            return icons.collectionView.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
        }
        icons.handleMiddleMouse(at: try point("f.txt"), down: true)
        icons.handleMiddleMouse(at: try point("f.txt"), down: false)
        icons.handleMiddleMouse(at: try point("A"), down: true)
        icons.handleMiddleMouse(at: try point("A"), down: false)
        try await w.h.waitUntil("background tab") { w.tabs == ["files", "A"] }
        XCTAssertEqual(w.selectedTab, 0)
    }

    func testSymlinkToAFolderOpensATabAndALinkToAFileDoesNothing() async throws {
        let w = try await world {
            try $0.dir("A"); try $0.file("f.txt")
            try $0.sandbox.createSymlink("files/LA", target: "A")
            try $0.sandbox.createSymlink("files/LF", target: "f.txt")
        }
        w.commands.openInNewTab(rows: [try row(w, "LF")], in: w.host.session.folder, select: false)
        w.commands.openInNewTab(rows: [try row(w, "LA")], in: w.host.session.folder, select: false)
        try await w.h.waitUntil("link tab") { w.tabs.count == 2 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(w.tabs.count, 2, "a link to a file opens nothing")
        XCTAssertEqual(w.tabs.last, "A", "OpenPlanner resolved the link")
        XCTAssertTrue(w.prompts.asked.isEmpty)
    }

    func testBrokenLinkShowsThePhase1Alert() async throws {
        let w = try await world { try $0.sandbox.createSymlink("files/broken", target: "nowhere") }
        w.commands.openInNewTab(rows: [try row(w, "broken")], in: w.host.session.folder, select: false)
        try await w.h.waitUntil("broken-link alert") { w.prompts.asked == [.brokenLink("broken")] }
        XCTAssertEqual(w.tabs.count, 1)
    }

    func testOpenInNewTabCommandOpensEverySelectedFolderAndSelectsTheFirst() async throws {
        let w = try await world { try $0.dir("A"); try $0.dir("B"); try $0.file("f.txt") }
        let folder = w.host.session.folder
        folder.select(.names(["A", "B", "f.txt"]))
        let target = CommandTarget.contentSelection(folder)
        XCTAssertTrue(w.commands.canPerform(.openInNewTab, target: target))
        w.commands.perform(.openInNewTab, target: target, sender: nil)
        try await w.h.waitUntil("two tabs") { w.tabs.count == 3 }
        XCTAssertEqual(w.tabs, ["files", "A", "B"])
        XCTAssertEqual(w.selectedTab, 1, "the first new tab is selected, the rest open behind it")
    }

    func testMoreThanTenFoldersAskFirst() async throws {
        let names = (1...11).map { "D\($0)" }
        let w = try await world { h in for n in names { try h.dir(n) } }
        let folder = w.host.session.folder
        folder.select(.names(names))
        w.prompts.confirmAnswers = [false]
        w.commands.perform(.openInNewTab, target: .contentSelection(folder), sender: nil)
        try await w.h.waitUntil("confirmation") { w.prompts.asked == [.openManyTabs(11)] }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(w.tabs.count, 1, "declined: nothing opens")
    }

    func testOpenInNewTabForASidebarTargetSelectsTheNewTab() async throws {
        let w = try await world { try $0.dir("A") }
        let target = CommandTarget.folder(w.h.url("A"))
        XCTAssertTrue(w.commands.canPerform(.openInNewTab, target: target))
        w.commands.perform(.openInNewTab, target: target, sender: nil)
        XCTAssertEqual(w.tabs, ["files", "A"])
        XCTAssertEqual(w.selectedTab, 1)
    }

    func testBackgroundTabsKeepTheCurrentlySelectedTab() async throws {
        let w = try await world { try $0.dir("A"); try $0.dir("B") }
        let a = w.h.context.windows.openTab(at: w.h.url("A"), in: w.host, select: true)
        w.h.context.windows.openTab(at: w.h.url("B"), in: w.host, select: false)
        XCTAssertEqual(w.tabs, ["files", "A", "B"])
        XCTAssertTrue(w.host.window?.tabGroup?.selectedWindow === a.window, "a background tab never re-selects the host")
    }

    // MARK: menus

    func testContextMenuOffersOpenInNewTabAfterOpenInNewWindowForFolders() async throws {
        let w = try await world { try $0.dir("A"); try $0.file("f.txt") }
        let content = try XCTUnwrap(w.host.contentPane as? ContentViewController)
        let folderMenu = try XCTUnwrap(content.contextMenu(forRow: try row(w, "A")))
        let titles = folderMenu.items.map(\.title)
        let window = try XCTUnwrap(titles.firstIndex(of: "Open in New Window"))
        XCTAssertEqual(titles[window + 1], "Open in New Tab")
        let fileMenu = try XCTUnwrap(content.contextMenu(forRow: try row(w, "f.txt")))
        XCTAssertFalse(fileMenu.items.map(\.title).contains("Open in New Tab"))
    }

    func testFileMenuItemIsEnabledForAFolderSelection() async throws {
        let w = try await world { try $0.dir("A"); try $0.file("f.txt") }
        let pane = try XCTUnwrap(w.host.contentPane)
        let item = MainMenuBuilder.item(.openInNewTab)
        w.host.session.folder.select(.names(["f.txt"]))
        XCTAssertFalse(pane.validateMenuItem(item))
        w.host.session.folder.select(.names(["A"]))
        XCTAssertTrue(pane.validateMenuItem(item))
    }

    // MARK: sidebar

    func testSidebarMenusOfferOpenInNewTab() async throws {
        let h = try await SidebarHarness.make(self) { try $0.dir("home/A") }
        let home = try XCTUnwrap(h.sidebar.menu(forRow: h.row(named: "Home", in: .favorites)))
        XCTAssertEqual(home.items.filter { !$0.isSeparatorItem }.map(\.title),
                       ["Open in New Window", "Open in New Tab", "Remove from Favorites"])
        let usb = try XCTUnwrap(h.sidebar.menu(forRow: h.row(named: "USB", in: .locations)))
        XCTAssertEqual(usb.items.map(\.title), ["Open in New Window", "Open in New Tab", "Eject", "Properties"])
        let handler = SidebarRecordingHandler()
        h.sidebar.handler = handler
        let newTab = usb.items[1]
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(newTab.action), to: newTab.target, from: newTab))
        XCTAssertEqual(handler.performed.map(\.0), [.openInNewTab])
    }

    func testCommandClickAndMiddleClickOnSidebarRowsOpenBackgroundTabsWithoutSelecting() async throws {
        let h = try await SidebarHarness.make(self) { try $0.dir("home/A") }
        var opened: [URL] = []
        h.sidebar.openBackgroundTab = { opened.append($0) }
        let selectedBefore = h.outline.selectedRow
        let usb = h.row(named: "USB", in: .locations)
        XCTAssertTrue(h.sidebar.handleNewTabGesture(.commandClick, row: usb))
        XCTAssertTrue(h.sidebar.handleNewTabGesture(.middleClick, row: h.row(named: "Home", in: .favorites)))
        XCTAssertFalse(h.sidebar.handleNewTabGesture(.middleClick, row: 0), "headers have no folder")
        XCTAssertEqual(opened.map { $0.standardizedFileURL.path }, [h.usb.standardizedFileURL.path, h.home.standardizedFileURL.path])
        XCTAssertEqual(h.outline.selectedRow, selectedBefore, "the sidebar selection is unchanged")
        XCTAssertEqual(h.session.folder.directory.standardizedFileURL.path, h.home.standardizedFileURL.path, "no navigation")
    }

    func testCommandClickInTheOutlineDoesNotChangeTheSelection() async throws {
        try ShellHarness.requireWindowServer()
        let h = try await SidebarHarness.make(self) { try $0.dir("home/A") }
        var opened: [URL] = []
        h.sidebar.openBackgroundTab = { opened.append($0) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = h.sidebar.view
        h.outline.layoutSubtreeIfNeeded()
        let before = h.outline.selectedRow
        let row = h.row(named: "USB", in: .locations)
        let rect = h.outline.rect(ofRow: row)
        let point = h.outline.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [.command], timestamp: 0,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                     clickCount: 1, pressure: 1))
        h.outline.mouseDown(with: click)
        XCTAssertEqual(opened.map { $0.standardizedFileURL.path }, [h.usb.standardizedFileURL.path])
        XCTAssertEqual(h.outline.selectedRow, before)
    }

    // MARK: scenario hooks

    func testScenarioHooksMiddleClickContentRowsAndTreeNodes() async throws {
        let w = try await world { try $0.dir("A"); try $0.dir("B"); try $0.file("A/a.txt") }
        let middle = try XCTUnwrap(w.host.scenarioHooks.performMiddleClick)
        let click = try XCTUnwrap(w.host.scenarioHooks.clickTarget)
        let ok1 = await middle("A")
        XCTAssertTrue(ok1)
        try await w.h.waitUntil("content tab") { w.tabs.count == 2 }
        let ok2 = await click("tree:B", ["cmd"])
        XCTAssertTrue(ok2)
        try await w.h.waitUntil("tree ⌘-click tab") { w.tabs.count == 3 }
        let ok3 = await middle("tree:A")
        XCTAssertTrue(ok3)
        try await w.h.waitUntil("tree middle-click tab") { w.tabs.count == 4 }
        XCTAssertEqual(w.tabs, ["files", "A", "B", "A"])
        XCTAssertEqual(w.selectedTab, 0)
        XCTAssertEqual(w.host.session.folder.directory.standardizedFileURL.path, w.h.filesRoot.standardizedFileURL.path)
        let missing = await middle("tree:nope")
        XCTAssertFalse(missing)
        let missingRow = await middle("nope")
        XCTAssertFalse(missingRow)
        let plain = await click("tree:B", [])
        XCTAssertTrue(plain)
        try await w.h.waitUntil("plain tree click navigates") { w.host.session.folder.directory.lastPathComponent == "B" }
    }

    // MARK: New Tab toolbar button (tab-bar drop fallback)

    func testNewTabToolbarItemIsInTheDefaultToolbar() async throws {
        let w = try await world { _ in }
        let toolbar = try XCTUnwrap(w.host.window?.toolbar)
        let item = try XCTUnwrap(toolbar.items.first { $0.itemIdentifier == ToolbarController.newTabID } as? NewTabToolbarItem)
        XCTAssertEqual(item.button.accessibilityIdentifier(), AXID.newTabItem)
        XCTAssertEqual(item.button.accessibilityLabel(), "New Tab")
        XCTAssertEqual(item.button.action, #selector(NSResponder.newWindowForTab(_:)))
        XCTAssertTrue(item.button.registeredDraggedTypes.contains(.fileURL))
        item.button.performClick(nil)
        XCTAssertEqual(w.tabs.count, 2, "click = ⌘T")
    }

    func testDroppingFoldersOnTheNewTabButtonOpensTabsAndLeavesThemInPlace() async throws {
        let w = try await world { try $0.dir("A"); try $0.dir("B"); try $0.file("f.txt") }
        let toolbar = try XCTUnwrap(w.host.window?.toolbar)
        let item = try XCTUnwrap(toolbar.items.first { $0.itemIdentifier == ToolbarController.newTabID } as? NewTabToolbarItem)
        let dirs = ["A", "B"].map { URL(filePath: w.h.url($0).path(percentEncoded: false), directoryHint: .isDirectory) }
        let file = URL(filePath: w.h.url("f.txt").path(percentEncoded: false), directoryHint: .notDirectory)
        XCTAssertEqual(NewTabButton.dragOperation(for: dirs + [file]), .link)
        XCTAssertEqual(NewTabButton.dragOperation(for: [file]), [])
        let opened = await item.button.openDropped(dirs + [file])
        XCTAssertTrue(opened)
        XCTAssertEqual(w.tabs, ["files", "A", "B"])
        XCTAssertEqual(w.selectedTab, 1)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: w.h.url("A").path, isDirectory: &isDir) && isDir.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: w.h.url("B").path))
    }
}
