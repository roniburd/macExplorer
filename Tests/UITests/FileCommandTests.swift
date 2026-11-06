// Tests/UITests/FileCommandTests.swift
import XCTest
import AppKit
@testable import UI
import Core
import MacxFS

@MainActor
final class ScriptedCommandPrompts: CommandPrompts {
    var confirmAnswers: [Bool] = []
    private(set) var asked: [CommandPrompt] = []
    var chosenFile: URL?
    var brokenLinkChoice: BrokenLinkChoice = .cancel
    var name: String?

    func confirm(_ prompt: CommandPrompt, window: NSWindow?) async -> Bool {
        asked.append(prompt)
        return confirmAnswers.isEmpty ? false : confirmAnswers.removeFirst()
    }
    func inform(_ prompt: CommandPrompt, window: NSWindow?) async { asked.append(prompt) }
    func brokenLink(_ name: String, window: NSWindow?) async -> BrokenLinkChoice {
        asked.append(.brokenLink(name))
        return brokenLinkChoice
    }
    func chooseFile(directory: URL?, applicationsOnly: Bool, window: NSWindow?) async -> URL? { chosenFile }
    func askName(current: String, window: NSWindow?) async -> String? { name }
}

@MainActor
final class FileCommandTests: XCTestCase {
    @MainActor
    private struct World {
        let h: ContentTestHarness
        let browser: BrowserWindowController
        let content: ContentViewController
        let commands: FileCommandController
        let prompts: ScriptedCommandPrompts
        var folder: FolderModel { browser.session.folder }
        var selection: CommandTarget { .contentSelection(folder) }
        func select(_ names: [String]) { folder.select(.names(names)) }
    }

    private func world(_ setup: (ContentTestHarness) throws -> Void) async throws -> World {
        let h = try await ContentTestHarness.make(self)
        try setup(h)
        let browser = try await h.openBrowserWindow()
        let content = try h.content(of: browser)
        let commands = try XCTUnwrap(content.handler as? FileCommandController, "P1-35 installs FileCommandController")
        let prompts = ScriptedCommandPrompts()
        commands.prompts = prompts
        return World(h: h, browser: browser, content: content, commands: commands, prompts: prompts)
    }

    func testCopyPasteIntoSameFolderMakesFinderStyleCopy() async throws {
        let w = try await world { try $0.file("a.txt") }
        w.select(["a.txt"])
        w.commands.perform(.copy, target: w.selection, sender: nil)
        w.commands.perform(.paste, target: w.selection, sender: nil)
        try await w.h.waitUntil("copy made") { w.h.exists("a copy.txt") }
        XCTAssertTrue(w.h.exists("a.txt"))
    }

    func testCutPasteIntoFolderMovesAndClearsCut() async throws {
        let w = try await world { try $0.file("a.txt"); try $0.dir("sub") }
        w.select(["a.txt"])
        w.commands.perform(.cut, target: w.selection, sender: nil)
        try await w.h.waitUntil("dimmed") { w.folder.row(named: "a.txt").map(w.folder.isCut(row:)) == true }
        w.commands.perform(.paste, target: .folder(w.h.url("sub")), sender: nil)
        try await w.h.waitUntil("moved") { w.h.exists("sub/a.txt") && !w.h.exists("a.txt") }
        try await w.h.waitUntil("cut cleared") { w.h.environment.clipboard.cutURLs.isEmpty }
    }

    func testPasteIgnoresSelectionAndUsesCurrentFolder() async throws {
        let w = try await world { try $0.file("a.txt"); try $0.dir("sub") }
        w.select(["a.txt"])
        w.commands.perform(.copy, target: w.selection, sender: nil)
        w.select(["sub"])
        w.commands.perform(.paste, target: w.selection, sender: nil)
        try await w.h.waitUntil("pasted into the current folder") { w.h.exists("a copy.txt") }
        XCTAssertFalse(w.h.exists("sub/a.txt"), "⌘V never pastes into the selected folder (§5.6)")
    }

    func testCutDimsRowsAndEscapeClears() async throws {
        let w = try await world { try $0.file("a.txt") }
        w.select(["a.txt"])
        w.commands.perform(.cut, target: w.selection, sender: nil)
        try await w.h.waitUntil("dimmed") { w.folder.cutNames == ["a.txt"] }
        w.commands.perform(.cancelOperation, target: w.selection, sender: nil)
        try await w.h.waitUntil("undimmed") { w.folder.cutNames.isEmpty }
    }

    func testMoveItemHereMovesCopiedItems() async throws {
        let w = try await world { try $0.file("sub/b.txt") }
        w.h.environment.clipboard.copy([w.h.url("sub/b.txt")])
        w.commands.perform(.moveItemHere, target: w.selection, sender: nil)
        try await w.h.waitUntil("moved here") { w.h.exists("b.txt") && !w.h.exists("sub/b.txt") }
    }

    func testTrashGoesToSandboxTrashAndUndoRestores() async throws {
        let w = try await world { try $0.file("a.txt") }
        w.select(["a.txt"])
        w.commands.perform(.moveToTrash, target: w.selection, sender: nil)
        try await w.h.waitUntil("trashed") { !w.h.exists("a.txt") }
        let trash = w.h.sandbox.root.appending(path: ".trash")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: trash.path).isEmpty)
        try await w.h.waitUntil("undo registered") { w.h.environment.undo.canUndo }
        w.commands.perform(.undo, target: w.selection, sender: nil)
        try await w.h.waitUntil("restored") { w.h.exists("a.txt") }
    }

    func testDeletePermanentlyAsksFirst() async throws {
        let w = try await world { try $0.file("a.txt") }
        w.select(["a.txt"])
        w.prompts.confirmAnswers = [false]
        w.commands.perform(.deletePermanently, target: w.selection, sender: nil)
        try await w.h.waitUntil("asked") { w.prompts.asked == [.confirmDelete(1)] }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(w.h.exists("a.txt"))
        w.prompts.confirmAnswers = [true]
        w.commands.perform(.deletePermanently, target: w.selection, sender: nil)
        try await w.h.waitUntil("deleted") { !w.h.exists("a.txt") }
    }

    func testNewFolderStartsInlineRename() async throws {
        let w = try await world { try $0.file("a.txt") }
        w.commands.perform(.newFolder, target: w.selection, sender: nil)
        try await w.h.waitUntil("created") { w.h.exists("New Folder") }
        try await w.h.waitUntil("renaming") {
            (w.content.activeList as? InlineRenameHost)?.renameController?.currentText == "New Folder"
        }
    }

    func testCopyAsPathWritesTextOnly() async throws {
        let w = try await world { try $0.file("a.txt"); try $0.file("b.txt") }
        w.select(["a.txt", "b.txt"])
        w.commands.perform(.copyAsPath, target: w.selection, sender: nil)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(w.h.pasteboardName))
        XCTAssertEqual(pasteboard.string(forType: .string), [w.h.url("a.txt").path, w.h.url("b.txt").path].joined(separator: "\n"))
        XCTAssertFalse(pasteboard.types?.contains(.fileURL) ?? false, "a later ⌘V must not paste files")
    }

    func testOpenFolderNavigatesAndDocumentUsesLaunchServices() async throws {
        let w = try await world { try $0.file("sub/doc.txt") }
        w.select(["sub"])
        w.commands.perform(.open, target: w.selection, sender: nil)
        try await w.h.waitUntil("navigated") { w.folder.directory.standardizedFileURL.path == w.h.url("sub").standardizedFileURL.path }
        try await w.h.waitUntil("sub listed") { w.folder.state == .complete }
        w.select(["doc.txt"])
        w.commands.perform(.open, target: w.selection, sender: nil)
        let fake = try XCTUnwrap(w.h.environment.launchServices.provider as? FakeLaunchServices)
        try await w.h.waitUntil("opened with the default app") { fake.opened().last?.files.first?.lastPathComponent == "doc.txt" }
        XCTAssertNil(fake.opened().last?.app)
    }

    func testOpenInTerminalUsesConfiguredApp() async throws {
        let w = try await world { try $0.file("a.txt") }
        w.commands.perform(.openInTerminal, target: .currentFolder(w.folder), sender: nil)
        let fake = try XCTUnwrap(w.h.environment.launchServices.provider as? FakeLaunchServices)
        try await w.h.waitUntil("terminal asked") { !fake.opened().isEmpty }
        XCTAssertEqual(fake.opened().last?.app?.path, "/System/Applications/Utilities/Terminal.app")
        XCTAssertEqual(fake.opened().last?.files.first?.standardizedFileURL, w.h.url("").standardizedFileURL)
    }

    func testFavoritesTrashRemovesFavoriteNotFolder() async throws {
        let w = try await world { try $0.dir("fav") }
        let lanes = w.h.environment.lanes
        let favorite = try await FavoritesResolver.makeFavorite(for: w.h.url("fav"), lanes: lanes)
        w.h.environment.settings.favorites = [favorite]
        let resolvedAll = await FavoritesResolver.resolve([favorite], lanes: lanes)
        let resolved = try XCTUnwrap(resolvedAll.first)
        w.commands.perform(.moveToTrash, target: .favorite(resolved), sender: nil)
        XCTAssertTrue(w.h.environment.settings.favorites.isEmpty)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(w.h.exists("fav"), "never trashes the target (§5.4)")
    }

    func testLocationsDisableTrashAndCut() async throws {
        let w = try await world { try $0.file("a.txt") }
        let volume = try XCTUnwrap(w.h.environment.volumes.volume(for: w.h.url("")))
        XCTAssertFalse(w.commands.canPerform(.moveToTrash, target: .volume(volume)))
        XCTAssertFalse(w.commands.canPerform(.cut, target: .volume(volume)))
        XCTAssertFalse(w.commands.canPerform(.rename, target: .volume(volume)))
    }

    func testSelectAllNoneInvert() async throws {
        let w = try await world { for n in ["a", "b", "c"] { try $0.file(n) } }
        w.commands.perform(.selectAll, target: w.selection, sender: nil)
        XCTAssertEqual(w.folder.selection.rows, IndexSet(integersIn: 0..<3))
        w.select(["a"])
        w.commands.perform(.invertSelection, target: w.selection, sender: nil)
        XCTAssertEqual(w.folder.selection.rows, IndexSet([1, 2]))
        w.commands.perform(.selectNone, target: w.selection, sender: nil)
        XCTAssertTrue(w.folder.selection.isEmpty)
    }

    func testViewAndSortCommandsUpdateTheFolderViewAndModel() async throws {
        let w = try await world { try $0.file("a.txt") }
        w.commands.perform(.viewAsIcons, target: w.selection, sender: nil)
        XCTAssertTrue(w.content.activeList === w.content.icons)
        XCTAssertEqual(w.h.environment.settings.viewMode, .details, "per folder: the global default is untouched")
        XCTAssertEqual(w.h.environment.folderViews.settings(for: w.folder.directory)?.viewMode, .icons)
        w.commands.perform(.sortBySize, target: w.selection, sender: nil)
        XCTAssertEqual(w.folder.query.sort.field, .size)
        XCTAssertEqual(w.h.environment.folderViews.settings(for: w.folder.directory)?.sort?.field, .size)
        XCTAssertEqual(w.h.environment.settings.sort.field, .name)
        let hidden = w.h.environment.settings.showHidden
        w.commands.perform(.toggleHidden, target: w.selection, sender: nil)
        XCTAssertEqual(w.h.environment.settings.showHidden, !hidden)
        XCTAssertEqual(w.folder.query.showHidden, !hidden)
    }

    func testHandlerInstalledInBrowserWindows() async throws {
        let w = try await world { try $0.file("a.txt") }
        XCTAssertTrue(w.content.handler === w.commands)
        let sidebar = try XCTUnwrap(w.browser.contentViewController?.firstDescendant(of: SidebarViewController.self))
        XCTAssertTrue(sidebar.handler === w.commands)
    }
}
