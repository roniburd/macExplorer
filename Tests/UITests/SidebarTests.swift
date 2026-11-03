import XCTest
import AppKit
@testable import UI
@testable import Core
import MacxFS
import MacxFixtures

/// SidebarViewController (§5.4) on sandbox volumes: sections, favorites, locations, eject, the Folders tree,
/// focus semantics, auto-reveal and persisted collapse state.
@MainActor
final class SidebarTests: XCTestCase {
    // MARK: sections

    func testSectionsInOrderAndExpandedByDefault() async throws {
        let h = try await SidebarHarness.make(self)
        XCTAssertEqual(h.sidebar.sectionHeaders, [.favorites, .locations, .folders])
        let headers = (0..<h.outline.numberOfRows).compactMap { h.sidebar.item(atRow: $0) }.filter(\.isHeader)
        XCTAssertEqual(headers.map(\.section), [.favorites, .locations, .folders])
        for section in SidebarSection.allCases {
            XCTAssertTrue(h.outline.isItemExpanded(h.sidebar.box(.header(section))), "\(section)")
            XCTAssertTrue(h.sidebar.outlineView(h.outline, isGroupItem: h.sidebar.box(.header(section))))
        }
        XCTAssertEqual(h.sidebar.view.accessibilityIdentifier(), AXID.sidebar)
        XCTAssertTrue(h.outline.acceptsFirstResponder)
    }

    func testCollapsedSectionsPersistBothWays() async throws {
        let h = try await SidebarHarness.make(self)
        h.outline.collapseItem(h.sidebar.box(.favoritesHeader))
        XCTAssertEqual(h.settings.collapsedSections, [.favorites])
        XCTAssertTrue(h.names(in: .favorites).isEmpty)
        h.outline.expandItem(h.sidebar.box(.favoritesHeader))
        XCTAssertEqual(h.settings.collapsedSections, [])
        h.settings.collapsedSections.insert(.locations)
        try await h.waitUntil("settings collapse the header") { !h.outline.isItemExpanded(h.sidebar.box(.locationsHeader)) }
        XCTAssertEqual(h.settings.collapsedSections, [.locations])
    }

    func testCollapsedStateIsRestoredForANewSidebar() async throws {
        let h = try await SidebarHarness.make(self) { $0.settings.collapsedSections = [.folders] }
        XCTAssertFalse(h.outline.isItemExpanded(h.sidebar.box(.foldersHeader)))
        XCTAssertTrue(h.outline.isItemExpanded(h.sidebar.box(.favoritesHeader)))
    }

    // MARK: favorites

    func testDefaultFavoritesShowOnlyExistingAndVisibleOnes() async throws {
        let h = try await SidebarHarness.make(self) { h in try h.dir("home/Desktop"); try h.dir("home/Documents") }
        XCTAssertEqual(h.names(in: .favorites), ["Home", "Desktop", "Documents"], "no Downloads folder, Applications hidden")
        h.settings.hiddenDefaultFavorites.insert(.desktop)
        await h.settle()
        XCTAssertEqual(h.names(in: .favorites), ["Home", "Documents"])
        try h.dir("home/Downloads")
        h.settings.hiddenDefaultFavorites.remove(.desktop)
        await h.settle()
        XCTAssertEqual(h.names(in: .favorites), ["Home", "Desktop", "Documents", "Downloads"])
    }

    func testAddFoldersSkipsFilesAndDuplicatesAndKeepsOrder() async throws {
        let h = try await SidebarHarness.make(self) { h in
            try h.dir("work"); try h.dir("photos"); try h.file("notes.txt")
        }
        let added = await h.sidebar.addFavorites([h.url("work"), h.url("notes.txt"), h.url("home"), h.url("work")],
                                                 atChildIndex: 99)
        XCTAssertEqual(added, 1, "a file, a default's folder and a duplicate are skipped")
        await h.settle()
        XCTAssertEqual(h.names(in: .favorites), ["Home", "work"])
        await h.sidebar.addFavorites([h.url("photos")], atChildIndex: 1)
        await h.settle()
        XCTAssertEqual(h.names(in: .favorites), ["Home", "photos", "work"], "inserted where dropped, after the defaults")
        XCTAssertEqual(h.settings.favorites.map(\.displayName), ["photos", "work"])
    }

    func testReorderFavorites() async throws {
        let h = try await SidebarHarness.make(self) { h in try h.dir("a"); try h.dir("b"); try h.dir("c") }
        await h.sidebar.addFavorites([h.url("a"), h.url("b"), h.url("c")], atChildIndex: 1)
        await h.settle()
        XCTAssertEqual(h.names(in: .favorites), ["Home", "a", "b", "c"])
        let a = h.settings.favorites[0].id
        XCTAssertTrue(h.sidebar.moveFavorite(id: a, toChildIndex: 4), "drop below the last row")
        await h.settle()
        XCTAssertEqual(h.names(in: .favorites), ["Home", "b", "c", "a"])
        XCTAssertTrue(h.sidebar.moveFavorite(id: a, toChildIndex: 0), "drop above the defaults lands first among bookmarks")
        await h.settle()
        XCTAssertEqual(h.names(in: .favorites), ["Home", "a", "b", "c"])
        XCTAssertFalse(h.sidebar.moveFavorite(id: SidebarFavoritesModel.defaultID(.home), toChildIndex: 3), "defaults don't move")
    }

    func testFavoritesDropValidationUsesThePasteboard() async throws {
        let h = try await SidebarHarness.make(self) { try $0.dir("work") }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("macx-tests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertEqual(h.sidebar.favoritesDropOperation(pasteboard, childIndex: 0), [])
        pasteboard.writeObjects([h.url("work") as NSURL])
        XCTAssertEqual(h.sidebar.favoritesDropOperation(pasteboard, childIndex: 0), .link)
        XCTAssertEqual(SidebarViewController.fileURLs(pasteboard).map(\.lastPathComponent), ["work"])
        pasteboard.clearContents()
        let id = UUID()
        pasteboard.setString(id.uuidString, forType: SidebarViewController.favoritePasteboardType)
        XCTAssertEqual(h.sidebar.favoritesDropOperation(pasteboard, childIndex: 0), .move)
        XCTAssertEqual(SidebarViewController.draggedFavoriteID(pasteboard), id)
    }

    func testOnlyUserFavoritesAreDraggable() async throws {
        let h = try await SidebarHarness.make(self) { try $0.dir("work") }
        await h.sidebar.addFavorites([h.url("work")], atChildIndex: 1)
        await h.settle()
        let home = h.sidebar.item(atRow: h.row(named: "Home", in: .favorites))
        let work = h.sidebar.item(atRow: h.row(named: "work", in: .favorites))
        XCTAssertNil(h.sidebar.outlineView(h.outline, pasteboardWriterForItem: h.sidebar.box(home!)))
        let writer = try XCTUnwrap(h.sidebar.outlineView(h.outline, pasteboardWriterForItem: h.sidebar.box(work!)) as? NSPasteboardItem)
        XCTAssertEqual(writer.string(forType: SidebarViewController.favoritePasteboardType), h.settings.favorites[0].id.uuidString)
    }

    func testStaleFavoriteIsDimmedOffersLocateAndCanBeRelocated() async throws {
        let h = try await SidebarHarness.make(self) { h in try h.dir("old"); try h.dir("new") }
        await h.sidebar.addFavorites([h.url("old")], atChildIndex: 1)
        await h.settle()
        try h.sandbox.remove("boot/old")
        h.sidebar.favorites.refresh()
        await h.settle()
        let row = h.row(named: "old", in: .favorites)
        guard case .favorite(let stale)? = h.sidebar.item(atRow: row) else { return XCTFail("favorite row") }
        XCTAssertTrue(stale.isStale)
        XCTAssertNil(stale.url)
        let cell = try XCTUnwrap(h.cell(atRow: row))
        XCTAssertEqual(cell.textField?.textColor, .tertiaryLabelColor, "dimmed")
        let menu = try XCTUnwrap(h.sidebar.menu(forRow: row))
        XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.title), ["Locate…", "Remove from Favorites"])

        var asked: String?
        h.sidebar.pickFolder = { message, _ in asked = message; return h.url("new") }
        h.sidebar.activateRow(row)                      // clicking a stale favorite = Locate…
        try await h.waitUntil("relocated") { h.settings.favorites.first?.displayName == "new" }
        XCTAssertNotNil(asked)
        XCTAssertEqual(h.settings.favorites.first?.id, stale.id, "same favorite, new bookmark")
        await h.settle()
        XCTAssertEqual(h.names(in: .favorites), ["Home", "new"])
        guard case .favorite(let fixed)? = h.sidebar.item(atRow: h.row(named: "new", in: .favorites)) else { return XCTFail() }
        XCTAssertFalse(fixed.isStale)
    }

    func testRemoveFromFavoritesNeverTouchesTheFolder() async throws {
        let h = try await SidebarHarness.make(self) { h in try h.dir("work"); try h.file("work/keep.txt"); try h.dir("home/Desktop") }
        let window = BrowserWindowController(context: h.context, initialURL: h.url("home"))
        defer { window.close() }
        let shell = ShellCommandHandler(context: h.context, window: window)
        h.sidebar.handler = shell
        await h.sidebar.addFavorites([h.url("work")], atChildIndex: 9)
        await h.settle()
        h.sidebar.select(row: h.row(named: "work", in: .favorites))
        XCTAssertEqual(h.sidebar.focusContext, .sidebarFavorites)
        h.sidebar.run(.moveToTrash, sender: nil)        // Del / ⌘⌫ → Remove from Favorites (§5.4)
        XCTAssertEqual(h.settings.favorites, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: h.sandbox.url("boot/work/keep.txt").path(percentEncoded: false)))
        let jobs = await h.environment.fileOps.snapshots()
        XCTAssertTrue(jobs.isEmpty, "no file operation")
        await h.settle()
        h.sidebar.select(row: h.row(named: "Desktop", in: .favorites))
        h.sidebar.run(.moveToTrash, sender: nil)
        XCTAssertTrue(h.settings.hiddenDefaultFavorites.contains(.desktop), "a default is hidden")
        XCTAssertTrue(FileManager.default.fileExists(atPath: h.url("home/Desktop").path(percentEncoded: false)))
    }

    func testDelRemapIsAppliedBeforeTheHandler() async throws {
        let h = try await SidebarHarness.make(self)
        let recorder = SidebarRecordingHandler()
        h.sidebar.handler = recorder
        h.sidebar.select(row: h.row(named: "Home", in: .favorites))
        h.sidebar.run(.moveToTrash, sender: nil)
        XCTAssertEqual(recorder.performed.map(\.0), [.removeFromFavorites])
        let item = NSMenuItem(title: "", action: Selector(Command.moveToTrash.selectorName), keyEquivalent: "")
        XCTAssertTrue(h.sidebar.validateMenuItem(item))
        h.sidebar.select(row: -1)
        XCTAssertFalse(h.sidebar.validateMenuItem(item), "no row, no target")
    }

    // MARK: locations and eject

    func testLocationsListVolumesWithEjectButtonsAndFollowSettings() async throws {
        let h = try await SidebarHarness.make(self)
        XCTAssertEqual(h.names(in: .locations), ["Macintosh HD", "USB"])
        let bootCell = try XCTUnwrap(h.cell(atRow: h.row(named: "Macintosh HD", in: .locations)))
        let usbCell = try XCTUnwrap(h.cell(atRow: h.row(named: "USB", in: .locations)))
        XCTAssertTrue(bootCell.ejectButton.isHidden)
        XCTAssertFalse(usbCell.ejectButton.isHidden)
        XCTAssertEqual(usbCell.ejectButton.accessibilityLabel(), "Eject")
        h.settings.showExternalVolumesInSidebar = false
        try await h.waitUntil("external hidden") { h.names(in: .locations) == ["Macintosh HD"] }
        h.settings.showExternalVolumesInSidebar = true
        try await h.waitUntil("external back") { h.names(in: .locations) == ["Macintosh HD", "USB"] }
    }

    func testLocationsUpdateLiveWithTheVolumeList() async throws {
        let h = try await SidebarHarness.make(self)
        let disk = try h.sandbox.createDirectory("disk2")
        h.scanner.set(h.scanner.volumes.withLock { $0 } + [SandboxVolumeScanner.volume("uuid:d2", name: "Backup", at: disk, boot: false)])
        await h.environment.volumes.refresh()
        try await h.waitUntil("mounted") { h.names(in: .locations) == ["Macintosh HD", "Backup", "USB"] }
        XCTAssertEqual(h.sidebar.tree.roots.map(\.name), ["Macintosh HD", "Backup", "USB"])
        h.scanner.set([SandboxVolumeScanner.volume("uuid:boot", name: "Macintosh HD", at: h.boot, boot: true)])
        await h.environment.volumes.refresh()
        try await h.waitUntil("unmounted") { h.names(in: .locations) == ["Macintosh HD"] }
        XCTAssertFalse(h.rows(in: .folders).contains { if case .folder(let n) = $0 { n.name == "USB" } else { false } })
    }

    func testICloudDriveAppearsWhenItExists() async throws {
        let h = try await SidebarHarness.make(self) { try $0.dir("home/Library/Mobile Documents/com~apple~CloudDocs") }
        try await h.waitUntil("iCloud Drive row") { h.names(in: .locations) == ["Macintosh HD", "iCloud Drive", "USB"] }
        h.settings.showICloudInSidebar = false
        try await h.waitUntil("hidden by setting") { h.names(in: .locations) == ["Macintosh HD", "USB"] }
    }

    func testEjectButtonEjectsThroughTheHandler() async throws {
        let h = try await SidebarHarness.make(self)
        let window = BrowserWindowController(context: h.context, initialURL: h.url("home"))
        defer { window.close() }
        h.sidebar.handler = ShellCommandHandler(context: h.context, window: window)
        let usbCell = try XCTUnwrap(h.cell(atRow: h.row(named: "USB", in: .locations)))
        usbCell.ejectButton.performClick(nil)
        try await h.waitUntil("ejected") { h.ejector.ejected == ["usb"] }
        XCTAssertTrue(h.prompts.asked.isEmpty, "no running jobs, no question")
        XCTAssertTrue(h.prompts.failures.isEmpty)
    }

    func testEjectFailureNamesTheBlockingProcesses() async throws {
        let h = try await SidebarHarness.make(self)
        h.ejector.fail(with: .busy(processes: ["Preview", "mds"]))
        let usb = try XCTUnwrap(h.environment.volumes.browsable.first { $0.name == "USB" })
        let ejected = await EjectFlow(environment: h.environment, prompts: h.prompts).eject(usb, window: nil)
        XCTAssertFalse(ejected)
        XCTAssertEqual(h.prompts.failures.map(\.0), ["USB"])
        XCTAssertEqual(EjectFlow.failureDetail(.busy(processes: ["Preview", "mds"])), "It's in use by: Preview, mds.")
        XCTAssertEqual(EjectFlow.failureDetail(.busy(processes: [])), "It's in use by another app.")
        XCTAssertEqual(EjectFlow.failureMessage(volumeName: "USB"), "“USB” couldn't be ejected.")
    }

    func testLocationMenus() async throws {
        let h = try await SidebarHarness.make(self)
        let usb = try XCTUnwrap(h.sidebar.menu(forRow: h.row(named: "USB", in: .locations)))
        XCTAssertEqual(usb.items.map(\.title), ["Open in New Window", "Eject", "Properties"])
        let boot = try XCTUnwrap(h.sidebar.menu(forRow: h.row(named: "Macintosh HD", in: .locations)))
        XCTAssertEqual(boot.items.map(\.title), ["Open in New Window", "Properties"])
        let home = try XCTUnwrap(h.sidebar.menu(forRow: h.row(named: "Home", in: .favorites)))
        XCTAssertEqual(home.items.filter { !$0.isSeparatorItem }.map(\.title), ["Open in New Window", "Remove from Favorites"])
        XCTAssertNil(h.sidebar.menu(forRow: 0), "headers have no menu")
    }

    // MARK: focus and targets (§5.4 table)

    func testFocusContextAndTargetFollowTheSelectedRow() async throws {
        let h = try await SidebarHarness.make(self) { try $0.dir("a") }
        XCTAssertEqual(h.sidebar.focusContext, .sidebarFolders, "auto-reveal selected the tree node of home")
        guard case .folder(let url)? = h.sidebar.commandTarget else { return XCTFail("tree target") }
        XCTAssertEqual(ChangeBus.key(for: url), ChangeBus.key(for: h.url("home")))

        h.sidebar.select(row: h.row(named: "Home", in: .favorites))
        XCTAssertEqual(h.sidebar.focusContext, .sidebarFavorites)
        guard case .favorite(let favorite)? = h.sidebar.commandTarget else { return XCTFail("favorite target") }
        XCTAssertEqual(favorite.favorite.id, SidebarFavoritesModel.defaultID(.home))

        h.sidebar.select(row: h.row(named: "USB", in: .locations))
        XCTAssertEqual(h.sidebar.focusContext, .sidebarLocations)
        guard case .volume(let volume)? = h.sidebar.commandTarget else { return XCTFail("volume target") }
        XCTAssertEqual(volume.name, "USB")

        h.sidebar.select(row: h.row(named: "Macintosh HD", in: .folders))
        XCTAssertEqual(h.sidebar.focusContext, .sidebarVolumeRoot, "tree volume roots behave like Locations")
        guard case .volume? = h.sidebar.commandTarget else { return XCTFail("volume root target") }

        h.sidebar.select(row: -1)
        XCTAssertNil(h.sidebar.commandTarget)
    }

    // MARK: navigation and the tree

    func testSelectingRowsNavigates() async throws {
        let h = try await SidebarHarness.make(self) { try $0.dir("home/Documents") }
        h.outline.selectRowIndexes([h.row(named: "Documents", in: .favorites)], byExtendingSelection: false)
        XCTAssertEqual(ChangeBus.key(for: h.session.folder.directory), ChangeBus.key(for: h.url("home/Documents")))
        await h.settle()
        XCTAssertEqual(h.sidebar.focusContext, .sidebarFavorites, "auto-reveal keeps the favorite selected")
        h.outline.selectRowIndexes([h.row(named: "USB", in: .locations)], byExtendingSelection: false)
        XCTAssertEqual(h.session.folder.directory, h.usb)
        await h.settle()
        h.outline.selectRowIndexes([h.row(named: "home", in: .folders)], byExtendingSelection: false)
        XCTAssertEqual(ChangeBus.key(for: h.session.folder.directory), ChangeBus.key(for: h.url("home")))
    }

    func testReturnActivatesTheSelectedRow() async throws {
        let h = try await SidebarHarness.make(self)
        h.sidebar.select(row: h.row(named: "USB", in: .locations))
        XCTAssertNotEqual(h.session.folder.directory, h.usb, "programmatic selection doesn't navigate")
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: 0, context: nil, characters: "\r",
                                                   charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        h.outline.keyDown(with: event)
        XCTAssertEqual(h.session.folder.directory, h.usb)
    }

    func testAutoRevealExpandsAndSelectsTheCurrentFolder() async throws {
        let h = try await SidebarHarness.make(self) { try $0.dir("a/b/c") }
        h.session.navigate(to: h.url("a/b/c"))
        await h.settle()
        guard case .folder(let node)? = h.sidebar.selectedItem else { return XCTFail("tree node selected") }
        XCTAssertEqual(node.name, "c")
        XCTAssertEqual(node.pathFromRoot.map(\.name), ["Macintosh HD", "a", "b", "c"])
        for ancestor in node.pathFromRoot.dropLast() {
            XCTAssertTrue(h.outline.isItemExpanded(h.sidebar.box(.folder(ancestor))), ancestor.name)
        }
        XCTAssertGreaterThanOrEqual(h.sidebar.tree.watchedCount, 3, "expanded nodes are watched")
    }

    func testAutoRevealCanBeTurnedOff() async throws {
        let h = try await SidebarHarness.make(self) { $0.settings.autoRevealInTree = false; try $0.dir("a") }
        XCTAssertNil(h.sidebar.selectedItem)
        h.session.navigate(to: h.url("a"))
        await h.settle()
        XCTAssertNil(h.sidebar.selectedItem)
        h.settings.autoRevealInTree = true
        try await h.waitUntil("revealed when turned on") {
            if case .folder(let n)? = h.sidebar.selectedItem { n.name == "a" } else { false }
        }
    }

    func testTreeFollowsFileSystemChangesAndHiddenSetting() async throws {
        let h = try await SidebarHarness.make(self) { try $0.dir("a") }
        XCTAssertEqual(h.names(in: .folders), ["Macintosh HD", "a", "home", "USB"])
        try h.dir("new")
        try await h.waitUntil("vnode change shows up") { h.names(in: .folders) == ["Macintosh HD", "a", "home", "new", "USB"] }
        try h.dir(".hidden")
        h.settings.showHidden = true
        try await h.waitUntil("hidden shown") { h.names(in: .folders) == ["Macintosh HD", ".hidden", "a", "home", "new", "USB"] }
        h.settings.showHidden = false
        try await h.waitUntil("hidden gone") { h.names(in: .folders) == ["Macintosh HD", "a", "home", "new", "USB"] }
        if case .folder(let n)? = h.sidebar.selectedItem { XCTAssertEqual(n.name, "home", "selection survives reloads") }
        else { XCTFail("tree selection kept") }
    }

    func testLeftAndRightCollapseAndExpand() async throws {
        let h = try await SidebarHarness.make(self) { try $0.dir("a/b") }
        let row = h.row(named: "a", in: .folders)
        h.sidebar.select(row: row)
        let a = try XCTUnwrap(h.sidebar.selectedItem)
        func key(_ code: UInt16, _ char: Int) throws -> NSEvent {
            let s = String(UnicodeScalar(char)!)
            return try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function],
                                                  timestamp: 0, windowNumber: 0, context: nil, characters: s,
                                                  charactersIgnoringModifiers: s, isARepeat: false, keyCode: code))
        }
        h.outline.keyDown(with: try key(124, NSRightArrowFunctionKey))
        try await h.waitUntil("→ expands") { h.outline.isItemExpanded(h.sidebar.box(a)) && h.names(in: .folders).contains("b") }
        h.outline.keyDown(with: try key(123, NSLeftArrowFunctionKey))
        XCTAssertFalse(h.outline.isItemExpanded(h.sidebar.box(a)), "← collapses")
    }

    // MARK: window

    func testBrowserWindowsUseTheSidebar() async throws {
        let h = try await ShellHarness.make(self)
        let controller = try await h.openWindow()
        let sidebar = try XCTUnwrap(controller.sidebarPane as? SidebarViewController)
        XCTAssertNotNil(sidebar.handler)
        XCTAssertEqual(sidebar.tree.roots.map(\.url), [h.filesRoot], "--root: the tree never leaves the sandbox")
        XCTAssertFalse(sidebar.tree.roots[0].isVolumeRoot)
        try await h.waitUntil("root revealed and selected") { sidebar.selectedItem?.identity == SidebarItem.folder(sidebar.tree.roots[0]).identity }
        XCTAssertEqual(sidebar.focusContext, .sidebarFolders)
        guard case .folder(let url)? = sidebar.commandTarget else { return XCTFail("folder target") }
        XCTAssertEqual(url, h.filesRoot)
        controller.focus(.sidebarFavorites)
        XCTAssertTrue(controller.window?.firstResponder === sidebar.outlineView)
        XCTAssertEqual(controller.probeFocus, sidebar.focusContext)
        controller.close()
        XCTAssertEqual(sidebar.tree.watchedCount, 0, "closing the window closes the tree's vnode sources")
    }
}
