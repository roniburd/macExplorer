// Tests/UITests/ContextMenuTests.swift
import XCTest
import AppKit
@testable import UI
import Core
import MacxFS

@MainActor
final class ContextMenuTests: XCTestCase {
    private func ids(_ menu: NSMenu?) -> [String] {
        (menu?.items ?? []).filter { !$0.isSeparatorItem }.compactMap { $0.identifier?.rawValue }
    }

    private func item(_ menu: NSMenu?, _ command: Command) -> NSMenuItem? {
        menu?.items.first { $0.identifier?.rawValue == "macx.menu.\(command.rawValue)" }
    }

    private func box(_ menu: NSMenu?, _ command: Command) -> MenuActionBox? {
        item(menu, command)?.representedObject as? MenuActionBox
    }

    func testContextRowsRule() {
        let outside = ContextMenuBuilder.contextRows(clickedRow: 4, selectedRows: IndexSet([1, 2]))
        XCTAssertEqual(outside.select, .set(IndexSet(integer: 4), cursor: 4))
        XCTAssertEqual(outside.rows, IndexSet(integer: 4))
        let inside = ContextMenuBuilder.contextRows(clickedRow: 2, selectedRows: IndexSet([1, 2]))
        XCTAssertNil(inside.select)
        XCTAssertEqual(inside.rows, IndexSet([1, 2]))
        let empty = ContextMenuBuilder.contextRows(clickedRow: nil, selectedRows: IndexSet([1]))
        XCTAssertNil(empty.select)
        XCTAssertNil(empty.rows, "empty space → empty-space menu, selection kept")
    }

    func testRightClickOutsideSelectionSelectsOnlyThatRow() async throws {
        let h = try await ContentTestHarness.make(self)
        for name in ["a.txt", "b.txt", "c.txt"] { try h.file(name) }
        let content = try h.content(of: try await h.openBrowserWindow())
        content.session.folder.select(.set(IndexSet([0, 1]), cursor: 1))
        let menu = content.contextMenu(forRow: 2)
        XCTAssertEqual(content.session.folder.selection.rows, IndexSet(integer: 2))
        guard case .contentSelection? = box(menu, .moveToTrash)?.target else { return XCTFail("acts on the selection") }
    }

    func testRightClickInsideSelectionKeepsSelection() async throws {
        let h = try await ContentTestHarness.make(self)
        for name in ["a.txt", "b.txt", "c.txt"] { try h.file(name) }
        let content = try h.content(of: try await h.openBrowserWindow())
        content.session.folder.select(.set(IndexSet([0, 2]), cursor: 2))
        _ = content.contextMenu(forRow: 0)
        XCTAssertEqual(content.session.folder.selection.rows, IndexSet([0, 2]))
    }

    func testItemMenuOrderForFile() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt")
        let content = try h.content(of: try await h.openBrowserWindow())
        XCTAssertEqual(ids(content.contextMenu(forRow: 0)), [
            "macx.menu.showInPreview", "macx.menu.open", "macx.menu.openWith", "macx.menu.quickLook", "macx.menu.cut", "macx.menu.copy", "macx.menu.copyAsPath",
            "macx.menu.copyPathAs", "macx.menu.duplicate", "macx.menu.makeAlias", "macx.menu.makeSymlink", "macx.menu.rename",
            "macx.menu.moveToTrash", "macx.menu.deletePermanently", "macx.menu.new", "macx.menu.revealInFinder",
            "macx.menu.openInTerminal", "macx.menu.share", "macx.menu.properties",
        ])
    }

    func testPreviewHeadsTheMenuForPreviewableFilesOnly() async throws {
        let h = try await ContentTestHarness.make(self)
        for name in ["a.md", "b.docx", "c.png", "d.pdf", "e.zip", "f.zzqq"] { _ = try h.file(name) }
        _ = try h.dir("g")
        let window = try await h.openBrowserWindow()
        let content = try h.content(of: window)
        let folder = content.session.folder
        try await h.waitUntil("listed") { folder.rowCount == 7 }
        func row(_ name: String) -> Int { (0..<folder.rowCount).first { folder.url(atRow: $0).lastPathComponent == name }! }
        for name in ["a.md", "b.docx", "c.png", "d.pdf"] {
            let menu = content.contextMenu(forRow: row(name))
            XCTAssertEqual(menu?.items.first?.identifier?.rawValue, "macx.menu.showInPreview", name)
            XCTAssertEqual(menu?.items.first?.title, "Preview")
            XCTAssertTrue(menu?.items[1].isSeparatorItem ?? false, "a separator under Preview")
        }
        for name in ["e.zip", "f.zzqq", "g"] {
            XCTAssertNil(item(content.contextMenu(forRow: row(name)), .showInPreview), name)
        }
        folder.select(.set(IndexSet([row("a.md"), row("c.png")]), cursor: row("c.png")))
        XCTAssertNil(item(content.contextMenu(forRow: row("a.md")), .showInPreview), "one item only")
    }

    func testPreviewOpensThePreviewPane() async throws {
        let h = try await ContentTestHarness.make(self)
        _ = try h.file("a.md")
        let window = try await h.openBrowserWindow()
        let content = try h.content(of: window)
        let split = try XCTUnwrap(window.splitController)
        XCTAssertFalse(split.isPreviewPaneVisible)
        let menu = content.contextMenu(forRow: 0)
        let preview = try XCTUnwrap(box(menu, .showInPreview))
        XCTAssertTrue(preview.validateMenuItem(try XCTUnwrap(item(menu, .showInPreview))))
        preview.run(nil)
        XCTAssertTrue(split.isPreviewPaneVisible)
        preview.run(nil)
        XCTAssertTrue(split.isPreviewPaneVisible, "Preview never hides the pane")
        try await h.waitUntil("previewed") { split.previewPane.probeState == "markdown" }
    }

    func testCopyPathAsSubmenuActsOnTheSelection() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt")
        let content = try h.content(of: try await h.openBrowserWindow())
        let menu = content.contextMenu(forRow: 0)
        let copyPathAs = menu?.items.first { $0.identifier?.rawValue == CopyPathMenu.submenuID }
        XCTAssertEqual(copyPathAs?.submenu?.items.map(\.title), ["POSIX Path", "~ Path", "File URL", "Name", "Quoted for Shell"])
        let boxes = (copyPathAs?.submenu?.items ?? []).compactMap { $0.representedObject as? MenuActionBox }
        XCTAssertEqual(boxes.map(\.command), CopyPathMenu.commands)
        for box in boxes {
            guard case .contentSelection = box.target else { return XCTFail("\(box.command) acts on the selection") }
        }
        boxes.first { $0.command == .copyName }?.run(nil)
        XCTAssertEqual(h.environment.clipboard.backend.readString(), "a.txt")
    }

    func testItemMenuOffersPasteIntoOnlyForSingleFolder() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.dir("sub"); try h.dir("sub2"); try h.file("a.txt")
        let content = try h.content(of: try await h.openBrowserWindow())
        let folder = content.session.folder
        let single = content.contextMenu(forRow: try XCTUnwrap(folder.row(named: "sub")))
        guard case .folder(let url)? = box(single, .paste)?.target else { return XCTFail("Paste into the right-clicked folder") }
        XCTAssertEqual(url.standardizedFileURL.path, h.url("sub").standardizedFileURL.path)
        XCTAssertNotNil(item(single, .openInNewWindow))
        folder.select(.set(IndexSet([0, 1]), cursor: 1))
        XCTAssertNil(item(content.contextMenu(forRow: 0), .paste), "two folders: no Paste")
        XCTAssertNil(item(content.contextMenu(forRow: try XCTUnwrap(folder.row(named: "a.txt"))), .paste), "a file: no Paste")
    }

    func testPackageShowsPackageContents() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.dir("Fake.app/Contents")
        let content = try h.content(of: try await h.openBrowserWindow())
        XCTAssertNotNil(item(content.contextMenu(forRow: 0), .showPackageContents))
    }

    func testEmptySpaceMenuItems() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt")
        let content = try h.content(of: try await h.openBrowserWindow())
        let menu = content.contextMenu(forRow: nil)
        XCTAssertEqual(ids(menu), ["macx.menu.paste", "macx.menu.new", "macx.menu.view", "macx.menu.sortBy", "macx.menu.groupBy",
                                   "macx.menu.refresh", "macx.menu.openInTerminal", "macx.menu.properties"])   // Group By ▸: P2-10
        guard case .currentFolder? = box(menu, .properties)?.target else { return XCTFail("Properties of the current folder") }
        let sortBy = menu?.items.first { $0.identifier?.rawValue == "macx.menu.sortBy" }?.submenu
        XCTAssertEqual(item(sortBy, .sortByName)?.state, .on)
    }

    func testMenuItemsValidateThroughHandler() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt")
        let content = try h.content(of: try await h.openBrowserWindow())
        let menu = content.contextMenu(forRow: nil)
        let paste = try XCTUnwrap(item(menu, .paste))
        let pasteBox = try XCTUnwrap(box(menu, .paste))
        XCTAssertFalse(pasteBox.validateMenuItem(paste), "nothing to paste")
        h.environment.clipboard.copy([h.url("a.txt")])
        XCTAssertTrue(pasteBox.validateMenuItem(paste))
    }

    func testOpenWithShowsLoadingThenApps() async throws {
        let h = try await ContentTestHarness.make(self)
        let file = try h.file("a.txt")
        let textEdit = AppInfo(url: URL(filePath: "/System/Applications/TextEdit.app"), name: "TextEdit", bundleIdentifier: "com.apple.TextEdit")
        let other = AppInfo(url: URL(filePath: "/Applications/Other.app"), name: "Other", bundleIdentifier: nil)
        let cache = LaunchServicesCache(provider: FakeLaunchServices(apps: [textEdit, other], defaultApp: textEdit))
        var opened: [URL] = []
        let openWith = OpenWithMenu(files: [file], typeIndex: TypeRegistry.shared.index(forExtension: "txt", isDirectory: false),
                                    cache: cache, icons: nil, openWith: { opened.append($0) }, other: {}, chooseDefault: {})
        XCTAssertEqual(openWith.menu.items.first?.title, "Loading…")
        try await h.waitUntil("apps loaded") { openWith.menu.items.first?.title == "TextEdit (default)" }
        let titles = openWith.menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        XCTAssertEqual(titles, ["TextEdit (default)", "Other", "Other…", "Choose Default App…"])
        XCTAssertEqual(openWith.menu.items.first?.state, .on)
        let otherItem = try XCTUnwrap(openWith.menu.items.first { $0.title == "Other" })
        openWith.menu.performActionForItem(at: openWith.menu.index(of: otherItem))
        XCTAssertEqual(opened, [other.url])
    }

    func testDefaultAppChoiceSetsBothDefaultsThenOpens() async throws {
        let h = try await ContentTestHarness.make(self)
        let file = try h.file("a.custom-ext")
        let app = URL(filePath: "/Applications/Other.app")
        let fake = FakeLaunchServices()
        try await DefaultAppChoice.apply(app: app, file: file, always: true, provider: fake)
        XCTAssertEqual(fake.defaultsSet().map(\.forType), [true, false], "content type first, then the per-file override (§5.7)")
        XCTAssertEqual(fake.defaultsSet().map(\.app), [app, app])
        XCTAssertEqual(fake.opened().map(\.files), [[file]])
        XCTAssertEqual(fake.opened().map(\.app), [app])
        let once = FakeLaunchServices()
        try await DefaultAppChoice.apply(app: app, file: file, always: false, provider: once)
        XCTAssertTrue(once.defaultsSet().isEmpty)
        XCTAssertEqual(once.opened().count, 1)
    }
}
