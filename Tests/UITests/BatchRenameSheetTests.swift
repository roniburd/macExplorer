import XCTest
import AppKit
@testable import UI
@testable import Core
import MacxFS

/// P4-12: the batch rename sheet (model, live preview, F2 on a multi-selection, Rename N Items…). Sandbox files only.
@MainActor final class BatchRenameSheetTests: XCTestCase {
    private func commands(_ ui: ContentTestHarness, _ window: BrowserWindowController) throws -> FileCommandController {
        try XCTUnwrap(ui.content(of: window).handler as? FileCommandController)
    }

    func testModelPreviewDebouncesAndApplies() async throws {
        let ui = try await ContentTestHarness.make(self)
        try ui.file("IMG_1.jpg"); try ui.file("IMG_2.jpg"); try ui.file("other.txt")
        let window = try await ui.openBrowserWindow()
        let folder = window.session.folder
        folder.select(.names(["IMG_1.jpg", "IMG_2.jpg"]))
        let model = BatchRenameModel(urls: folder.selectedURLs, folder: folder, context: ui.context, origin: window.origin)
        var n = BatchRenameRules.Numbering(); n.position = .replaceName; n.baseName = "Trip"
        model.rules.numbering = n
        model.rules.find = "x"                     // second change within the debounce window
        try await ui.waitUntil("preview") { model.preview?.rows.map(\.proposed) == ["Trip (1).jpg", "Trip (2).jpg"] }
        XCTAssertEqual(model.preview?.canApply, true)
        XCTAssertEqual(model.generationsComputed, 1, "the two edits inside 50 ms ran one preview")
        let outcome = await model.apply()
        XCTAssertEqual(outcome?.record.actions.count, 2)
        try await ui.waitUntil("rows") { window.probeRowNames.sorted() == ["Trip (1).jpg", "Trip (2).jpg", "other.txt"] }
        try await ui.waitUntil("renamed items selected") { window.probeSelectedNames.sorted() == ["Trip (1).jpg", "Trip (2).jpg"] }
        XCTAssertTrue(ui.exists("Trip (1).jpg")); XCTAssertFalse(ui.exists("IMG_1.jpg"))
    }

    func testCollisionWithUnselectedItemBlocksApply() async throws {
        let ui = try await ContentTestHarness.make(self)
        try ui.file("a.txt"); try ui.file("b.txt"); try ui.file("c.txt")
        let window = try await ui.openBrowserWindow()
        let folder = window.session.folder
        folder.select(.names(["a.txt", "b.txt"]))
        let model = BatchRenameModel(urls: folder.selectedURLs, folder: folder, context: ui.context, origin: window.origin)
        model.rules.find = "a"; model.rules.replace = "c"
        try await ui.waitUntil("preview") { model.preview != nil }
        XCTAssertEqual(model.preview?.rows.first?.status, .collidesWithExisting("c.txt"))
        XCTAssertEqual(model.preview?.canApply, false)
        let none = await model.apply()
        XCTAssertNil(none)
        XCTAssertEqual(window.probeRowNames.sorted(), ["a.txt", "b.txt", "c.txt"])
    }

    func testSwapIsAllowedAndOneUndoRestores() async throws {
        let ui = try await ContentTestHarness.make(self)
        try ui.file("a.txt", contents: Data("A".utf8)); try ui.file("b.txt", contents: Data("B".utf8))
        let window = try await ui.openBrowserWindow()
        let folder = window.session.folder
        folder.select(.names(["a.txt", "b.txt"]))
        let model = BatchRenameModel(urls: folder.selectedURLs, folder: folder, context: ui.context, origin: window.origin)
        model.rules.find = "^(a|b)"; model.rules.useRegex = true; model.rules.replace = "x$1"
        try await ui.waitUntil("preview") { model.preview?.canApply == true }
        _ = await model.apply()
        try await ui.waitUntil("renamed") { ui.exists("xa.txt") && ui.exists("xb.txt") }
        try await ui.waitUntil("undo registered") { ui.environment.undo.canUndo }
        try commands(ui, window).perform(.undo, target: .contentSelection(folder), sender: nil)
        try await ui.waitUntil("undone") { ui.exists("a.txt") && ui.exists("b.txt") && !ui.exists("xa.txt") }
        XCTAssertEqual(try String(contentsOf: ui.url("a.txt"), encoding: .utf8), "A")
    }

    func testF2WithMultiSelectionOpensSheetAndSingleStaysInline() async throws {
        let ui = try await ContentTestHarness.make(self)
        try ui.file("a.txt"); try ui.file("b.txt")
        let window = try await ui.openBrowserWindow()
        let folder = window.session.folder
        let commands = try commands(ui, window)
        folder.select(.names(["a.txt", "b.txt"]))
        XCTAssertTrue(commands.canPerform(.rename, target: .contentSelection(folder)))
        commands.perform(.rename, target: .contentSelection(folder), sender: nil)
        try await ui.waitUntil("sheet") { window.probeSheetTitle == "Rename 2 Items" }
        BatchRenameSheet.current(on: window.window)?.cancel()
        try await ui.waitUntil("sheet closed") { window.probeSheetTitle == nil }
        XCTAssertTrue(ui.exists("a.txt") && ui.exists("b.txt"), "Cancel changes nothing")
        folder.select(.names(["a.txt"]))
        commands.perform(.rename, target: .contentSelection(folder), sender: nil)
        try await ui.waitUntil("inline rename") { window.probeRenameText == "a.txt" }
        XCTAssertNil(window.probeSheetTitle)
    }

    func testSheetRenameButtonAppliesAndCloses() async throws {
        let ui = try await ContentTestHarness.make(self)
        try ui.file("a.txt"); try ui.file("b.txt")
        let window = try await ui.openBrowserWindow()
        let folder = window.session.folder
        folder.select(.names(["a.txt", "b.txt"]))
        try commands(ui, window).perform(.batchRename, target: .contentSelection(folder), sender: nil)
        let sheet = try XCTUnwrap(BatchRenameSheet.current(on: window.window))
        sheet.model.rules.prefix = "new-"
        try await ui.waitUntil("preview") { sheet.model.preview?.canApply == true }
        sheet.rename()
        try await ui.waitUntil("renamed") { ui.exists("new-a.txt") && ui.exists("new-b.txt") }
        try await ui.waitUntil("sheet closed") { window.probeSheetTitle == nil }
    }

    func testContextMenuTitle() async throws {
        let ui = try await ContentTestHarness.make(self)
        try ui.file("a.txt"); try ui.file("b.txt"); try ui.file("c.txt")
        let window = try await ui.openBrowserWindow()
        let folder = window.session.folder
        folder.select(.names(["a.txt", "b.txt", "c.txt"]))
        let menu = ContextMenuBuilder(context: ui.context).itemMenu(for: folder.selection.rows, in: folder, handler: try commands(ui, window))
        let item = try XCTUnwrap(menu.items.first { $0.identifier?.rawValue == "macx.menu.batchRename" })
        XCTAssertEqual(item.title, "Rename 3 Items…")
        XCTAssertFalse(menu.items.contains { $0.identifier?.rawValue == "macx.menu.rename" }, "one Rename entry")
        folder.select(.names(["a.txt"]))
        let single = ContextMenuBuilder(context: ui.context).itemMenu(for: folder.selection.rows, in: folder, handler: try commands(ui, window))
        XCTAssertNil(single.items.first { $0.identifier?.rawValue == "macx.menu.batchRename" })
    }

    func testPreviewTableHandlesTenThousandRows() {
        let rows = (0..<10_000).map {
            BatchRenameRow(url: URL(filePath: "/tmp/macx-x/\($0)"), original: "\($0)", proposed: "n\($0)", status: .ok, extensionChanged: false)
        }
        let table = BatchRenamePreviewTable.makeTableForTesting()
        let elapsed = ContinuousClock().measure { table.setRows(rows); table.tableView.layoutSubtreeIfNeeded() }
        XCTAssertEqual(table.tableView.numberOfRows, 10_000)
        XCTAssertLessThan(elapsed, .milliseconds(200))
    }

    func testStatusTexts() {
        XCTAssertEqual(BatchRenamePreviewTable.statusText(.duplicateInBatch, extensionChanged: false), "Duplicate name")
        XCTAssertEqual(BatchRenamePreviewTable.statusText(.collidesWithExisting("x"), extensionChanged: false), "Already exists")
        XCTAssertEqual(BatchRenamePreviewTable.statusText(.invalid(.containsSlash), extensionChanged: false), "Invalid name")
        XCTAssertEqual(BatchRenamePreviewTable.statusText(.invalidPattern("("), extensionChanged: false), "Invalid pattern")
        XCTAssertEqual(BatchRenamePreviewTable.statusText(.ok, extensionChanged: true), "Extension changes")
        XCTAssertEqual(BatchRenamePreviewTable.statusText(.unchanged, extensionChanged: false), "Unchanged")
        XCTAssertEqual(BatchRenamePreviewTable.statusText(.ok, extensionChanged: false), "")
    }
}
