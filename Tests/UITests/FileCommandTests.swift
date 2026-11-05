// Tests/UITests/FileCommandTests.swift
import XCTest
import AppKit
@testable import UI
import Core
import MacxFS
import MacxFixtures

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

    /// Review fix: the folder scan behind Open in New Tab runs only when that command is validated, not for every
    /// menu item / command-bar button (a 100k Select All would be walked once per validated item otherwise).
    func testSelectedFolderCountIsComputedOnlyForOpenInNewTab() async throws {
        let w = try await world { try $0.file("a.txt"); try $0.dir("sub") }
        w.select(["a.txt", "sub"])
        let env = w.h.environment, session = w.browser.session
        XCTAssertEqual(CommandStateBuilder.state(for: w.selection, session: session, environment: env).selectedFolderCount, 0)
        XCTAssertEqual(CommandStateBuilder.state(for: w.selection, session: session, environment: env,
                                                 needsFolderCount: true).selectedFolderCount, 1)
        w.select(["a.txt"])
        XCTAssertEqual(CommandStateBuilder.state(for: w.selection, session: session, environment: env,
                                                 needsFolderCount: true).selectedFolderCount, 0)
        XCTAssertFalse(w.commands.canPerform(.openInNewTab, target: w.selection))
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
        let backend = w.h.environment.clipboard.backend
        XCTAssertEqual(backend.readString(), [w.h.url("a.txt").path, w.h.url("b.txt").path].joined(separator: "\n"))
        XCTAssertFalse(backend.hasFileURLs(), "a later ⌘V must not paste files")
    }

    /// Review fix: Copy as Path keeps a precomposed (NFC) on-disk name precomposed (URL.path would decompose it).
    func testCopyAsPathKeepsNFCNamesFromTheFolder() async throws {
        let nfc = "caf\u{E9}.txt"
        // Foundation's file APIs decompose names (fileSystemRepresentation), so create the NFC name with open(2).
        let w = try await world { h in
            let path = h.url("").path(percentEncoded: false) + "/" + nfc
            let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
            guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            close(fd)
        }
        let row = try XCTUnwrap((0..<w.folder.rowCount).first { w.folder.name(atRow: $0).unicodeScalars.count == 8 })
        XCTAssertEqual(Array(w.folder.name(atRow: row).unicodeScalars), Array(nfc.unicodeScalars), "APFS keeps the NFC name")
        w.folder.select(.names([w.folder.name(atRow: row)]))
        w.commands.perform(.copyName, target: w.selection, sender: nil)
        XCTAssertEqual(w.h.environment.clipboard.backend.readString().map { Array($0.unicodeScalars) }, Array(nfc.unicodeScalars))
        w.commands.perform(.copyAsPath, target: w.selection, sender: nil)
        XCTAssertEqual(w.h.environment.clipboard.backend.readString()?.unicodeScalars.suffix(8).map { $0 }, Array(nfc.unicodeScalars))
    }

    func testCopyPathVariantsWriteTheirStyle() async throws {
        let w = try await world { try $0.dir("sub"); try $0.file("it's here.txt") }
        let backend = w.h.environment.clipboard.backend
        func plain(_ url: URL) -> String {
            var path = url.path(percentEncoded: false)
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            return path
        }
        let root = plain(w.folder.directory), home = plain(w.h.environment.settings.home)
        XCTAssertTrue(root.hasPrefix(home + "/"), "the sandbox environment's home is its root, which holds the folder")
        func copy(_ command: Command, _ target: CommandTarget? = nil) -> String? {
            XCTAssertTrue(w.commands.canPerform(command, target: target ?? w.selection), "\(command)")
            w.commands.perform(command, target: target ?? w.selection, sender: nil)
            return backend.readString()
        }
        w.select(["it's here.txt"])
        XCTAssertEqual(copy(.copyAsPath), root + "/it's here.txt")
        XCTAssertEqual(copy(.copyPathTilde), "~" + root.dropFirst(home.count) + "/it's here.txt")
        XCTAssertEqual(copy(.copyPathFileURL), URL(filePath: root + "/it's here.txt").absoluteString)
        XCTAssertEqual(copy(.copyName), "it's here.txt")
        XCTAssertEqual(copy(.copyPathShellQuoted), "'" + root + #"/it'\''s here.txt'"#)
        w.select(["sub", "it's here.txt"])
        XCTAssertEqual(copy(.copyName), "sub\nit's here.txt", "display order, folders first")
        XCTAssertEqual(copy(.copyPathFileURL), URL(filePath: root + "/sub", directoryHint: .isDirectory).absoluteString + "\n"
                       + URL(filePath: root + "/it's here.txt").absoluteString)
        XCTAssertFalse(backend.hasFileURLs())
    }

    func testCopyPathReplacesACutAndNeedsASelection() async throws {
        let w = try await world { try $0.file("a.txt") }
        w.select(["a.txt"])
        w.commands.perform(.cut, target: w.selection, sender: nil)
        XCTAssertFalse(w.h.environment.clipboard.cutURLs.isEmpty)
        w.commands.perform(.copyPathShellQuoted, target: w.selection, sender: nil)
        XCTAssertTrue(w.h.environment.clipboard.cutURLs.isEmpty, "the text replaced the cut items on the pasteboard")
        XCTAssertNil(w.h.environment.clipboard.pastePlan(into: w.folder.directory, moveItemHere: false))
        w.select([])
        for command in [Command.copyPathTilde, .copyPathFileURL, .copyName, .copyPathShellQuoted] {
            XCTAssertFalse(w.commands.canPerform(command, target: w.selection), "\(command) with nothing selected")
        }
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

    /// Review fix (P2-08): a mount point's listed fileID is the covered folder's, while every other route probes
    /// with stat (the mounted volume's root). Opening the row must key its view state the same way as back/forward,
    /// so one folder never gets two records. The image is created and mounted -nobrowse inside the test sandbox.
    func testOpeningAMountPointRowKeysItsViewStateLikeEveryOtherRoute() async throws {
        try XCTSkipUnless(DiskImage.isAvailable, "hdiutil not available")
        let w = try await world { try $0.file("a.txt") }
        let image = try DiskImage.create(in: w.h.sandbox, format: .apfs, sizeMB: 16)
        defer { try? image.detach() }
        let session = w.browser.session
        let env = w.h.environment
        await env.volumes.refresh()
        let mount = image.mountPoint.standardizedFileURL
        let mounted = try XCTUnwrap(env.volumes.volume(for: mount))
        try XCTSkipUnless(mounted.capabilities.idStable && mounted.id.raw.hasPrefix("uuid:"), "image volume lacks stable IDs")
        session.navigate(to: w.h.sandbox.root)
        try await w.h.waitUntil("sandbox root listed") { session.folder.state == .complete }
        w.select([image.relativeMountPath])
        w.commands.perform(.open, target: w.selection, sender: nil)
        try await w.h.waitUntil("opened the mount point") {
            session.folder.directory.standardizedFileURL.path == mount.path
        }
        try await w.h.waitUntil("identity known") { session.locator.fileID != nil }
        let opened = try XCTUnwrap(session.locator.objectKey)
        session.goBack()
        session.goForward()
        try await w.h.waitUntil("identity known again") { session.locator.fileID != nil }
        XCTAssertEqual(session.locator.objectKey, opened, "one folder, one key, whichever way it was reached")
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

    func testViewAndSortCommandsUpdateTheFolderViewStateAndModel() async throws {
        let w = try await world { try $0.file("a.txt") }
        w.commands.perform(.viewAsIcons, target: w.selection, sender: nil)
        XCTAssertTrue(w.content.activeList === w.content.icons)
        XCTAssertEqual(w.browser.session.viewState.mode, .icons)
        XCTAssertEqual(w.h.environment.settings.viewMode, .details, "per folder (P2-08)")
        w.commands.perform(.sortBySize, target: w.selection, sender: nil)
        XCTAssertEqual(w.folder.query.sort.field, .size)
        XCTAssertEqual(w.browser.session.viewState.sort.field, .size)
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
