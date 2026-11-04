// Tests/UITests/DragDropTests.swift
import XCTest
import AppKit
import Darwin
@testable import UI
import Core
import MacxFS

@MainActor
final class DragDropTests: XCTestCase {
    private func pasteboard(_ h: ContentTestHarness) -> NSPasteboard { NSPasteboard(name: NSPasteboard.Name(h.pasteboardName)) }

    func testDragPasteboardWritesEveryURLAndFilenames() async throws {
        let h = try await ContentTestHarness.make(self)
        let urls = try ["a", "b", "c"].map { try h.file($0) }
        let board = pasteboard(h)
        DragPasteboard.write(urls, secondary: false, to: board)
        let read = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        XCTAssertEqual(read?.map(\.standardizedFileURL), urls.map(\.standardizedFileURL), "one public.file-url item per URL")
        XCTAssertEqual(board.propertyList(forType: DragPasteboard.filenamesType) as? [String], urls.map(\.path))
        XCTAssertEqual(DragPasteboard.readURLs(from: board).map(\.path), urls.map(\.path))
        XCTAssertFalse(DragPasteboard.isSecondary(board))
    }

    func testDragPasteboardMarksSecondaryDrag() async throws {
        let h = try await ContentTestHarness.make(self)
        let board = pasteboard(h)
        DragPasteboard.write([try h.file("a")], secondary: true, to: board)
        XCTAssertTrue(DragPasteboard.isSecondary(board))
        XCTAssertEqual(DragPasteboard.secondaryType.rawValue, DropPolicy.secondaryDragType)
    }

    func testDragPasteboardWritesTenThousandQuickly() async throws {
        let h = try await ContentTestHarness.make(self)
        let urls = (0..<10_000).map { h.url("f\($0).txt") }   // paths only; nothing is created
        let start = ContinuousClock.now
        DragPasteboard.write(urls, secondary: false, to: pasteboard(h))
        XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(1_200), "budget: ≤10k in 300 ms release (overview §4.4 decision)")
        XCTAssertEqual(pasteboard(h).pasteboardItems?.count, 10_000)
        XCTAssertEqual(DragPasteboard.readURLs(from: pasteboard(h)).map(\.path), urls.map(\.path), "promised items read back")
    }

    func testDragImageComposerCapsAtFiveIcons() async throws {
        let h = try await ContentTestHarness.make(self)
        let icon = h.context.icons.typeIcon(TypeRegistry.dataIndex, points: 48, scale: 2)
        let one = DragImageComposer.image(icons: [icon], count: 1)
        let two = DragImageComposer.image(icons: [icon, icon], count: 2)
        let five = DragImageComposer.image(icons: Array(repeating: icon, count: 5), count: 5)
        let many = DragImageComposer.image(icons: Array(repeating: icon, count: 10), count: 10_000)
        XCTAssertLessThan(one.size.width, two.size.width)
        XCTAssertEqual(five.size, many.size, "at most 5 icons are drawn")
    }

    func testRightDragTrackerThreshold() {
        var tracker = RightDragTracker()
        tracker.rightMouseDown(at: NSPoint(x: 10, y: 10))
        XCTAssertEqual(tracker.rightMouseDragged(to: NSPoint(x: 12, y: 11)), .none)
        XCTAssertEqual(tracker.rightMouseUp(at: NSPoint(x: 12, y: 11)), .showMenu(at: NSPoint(x: 10, y: 10)), "small wobble → menu")
        tracker.rightMouseDown(at: NSPoint(x: 10, y: 10))
        XCTAssertEqual(tracker.rightMouseDragged(to: NSPoint(x: 14, y: 10)), .beginDrag)
        XCTAssertEqual(tracker.rightMouseDragged(to: NSPoint(x: 30, y: 10)), .none, "only one drag per press")
        XCTAssertEqual(tracker.rightMouseUp(at: NSPoint(x: 30, y: 10)), .none, "no menu after a drag")
        XCTAssertEqual(tracker.rightMouseUp(at: .zero), .none, "up without down")
    }

    /// Slice Review Focus 4.
    func testDropOnFileOrPackageRowTargetsCurrentFolder() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.dir("folder"); try h.file("file.txt"); try h.dir("Fake.app/Contents")
        let folder = try await h.openFolder()
        func destination(_ name: String, onRow: Bool = true) throws -> DropRetarget.Result {
            DropRetarget.destination(row: try XCTUnwrap(folder.row(named: name)), onRow: onRow, folder: folder)
        }
        XCTAssertEqual(try destination("folder"), DropRetarget.Result(url: folder.url(atRow: folder.row(named: "folder")!), retargetToFolder: false))
        XCTAssertEqual(try destination("file.txt"), DropRetarget.Result(url: folder.directory, retargetToFolder: true))
        XCTAssertEqual(try destination("Fake.app"), DropRetarget.Result(url: folder.directory, retargetToFolder: true), "packages are files (§5.7)")
        XCTAssertEqual(try destination("folder", onRow: false), DropRetarget.Result(url: folder.directory, retargetToFolder: true),
                       "between rows → the displayed folder")
        XCTAssertEqual(DropRetarget.destination(row: -1, onRow: true, folder: folder).url, folder.directory)
    }

    func testSpringLoadingOnlyForFolders() {
        XCTAssertTrue(SpringLoadPolicy.opens(.directory))
        for kind in [Kind.package, .file, .symlink, .alias, .other] { XCTAssertFalse(SpringLoadPolicy.opens(kind), "\(kind)") }
    }

    func testDropDestinationResolver() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.dir("sub"); try h.file("a.txt")
        let folder = try await h.openFolder()
        XCTAssertEqual(DropDestinationResolver.resolve("", folder: folder, favorites: []), folder.directory)
        XCTAssertEqual(DropDestinationResolver.resolve("sub", folder: folder, favorites: [])?.lastPathComponent, "sub")
        XCTAssertEqual(DropDestinationResolver.resolve("a.txt", folder: folder, favorites: []), folder.directory)
        XCTAssertNil(DropDestinationResolver.resolve("missing", folder: folder, favorites: []))
        let favorite = Favorite(bookmark: Data(), displayName: "Fav", lastKnownPath: h.url("sub").path)
        XCTAssertEqual(DropDestinationResolver.resolve("sidebar:Fav", folder: folder, favorites: [favorite])?.path, h.url("sub").path)
        let root = URL(filePath: "/", directoryHint: .isDirectory)
        let dir = URL(filePath: "/Users/x/dev", directoryHint: .isDirectory)
        XCTAssertEqual(DropDestinationResolver.crumbURL(0, of: dir, volumeRoot: root)?.path, "/")
        XCTAssertEqual(DropDestinationResolver.crumbURL(2, of: dir, volumeRoot: root)?.path, "/Users/x")
        XCTAssertEqual(DropDestinationResolver.crumbURL(3, of: dir, volumeRoot: root)?.standardizedFileURL, dir.standardizedFileURL)
        XCTAssertNil(DropDestinationResolver.crumbURL(4, of: dir, volumeRoot: root))
    }

    func testDropChoiceMapping() {
        let src = [URL(filePath: "/s/a")]
        let dst = URL(filePath: "/d", directoryHint: .isDirectory)
        XCTAssertEqual(DropChoice.copy.jobKind(sources: src, destination: dst), .copy(sources: src, destination: dst))
        XCTAssertEqual(DropChoice.move.jobKind(sources: src, destination: dst), .move(sources: src, destination: dst))
        XCTAssertEqual(DropChoice.alias.jobKind(sources: src, destination: dst), .alias(sources: src, destination: dst))
        XCTAssertEqual(DropChoice.symlink.jobKind(sources: src, destination: dst), .symlink(sources: src, destination: dst))
        XCTAssertNil(DropChoice.cancel.jobKind(sources: src, destination: dst))
        XCTAssertEqual(DropTarget.dragOperation(.copy), .copy)
        XCTAssertEqual(DropTarget.dragOperation(.move), .move)
        XCTAssertEqual(DropTarget.dragOperation(.alias), .link)
        XCTAssertEqual(DropTarget.dragOperation(.menu), .generic)
        XCTAssertEqual(DropTarget.dragOperation(.none), [])
        XCTAssertNil(DropChoice(menuChoice: DragOperation.none))
        XCTAssertEqual(DropChoice(menuChoice: .alias), .alias)
    }

    func testDropMenuTitles() {
        let menu = DropMenu.makeMenu { _ in }
        XCTAssertEqual(menu.items.map { $0.isSeparatorItem ? "-" : $0.title },
                       ["Copy Here", "Move Here", "Create Alias Here", "Create Symbolic Link Here", "-", "Cancel"])
    }

    func testRunMoveOnSameVolume() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt"); try h.dir("sub")
        let drops = DropTarget(context: h.context)
        let op = drops.operation(sources: [h.url("a.txt")], destination: h.url("sub"), modifiers: [], secondary: false)
        XCTAssertEqual(op, .move, "same volume moves by default")
        XCTAssertEqual(drops.operation(sources: [h.url("a.txt")], destination: h.url("sub"), modifiers: .option, secondary: false), .copy)
        XCTAssertTrue(drops.run(op, sources: [h.url("a.txt")], destination: h.url("sub"), menuAt: .zero, in: nil))
        try await h.waitUntil("moved") { h.exists("sub/a.txt") && !h.exists("a.txt") }
    }

    func testSelfOrDescendantDropIsRefused() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.dir("A/sub")
        let drops = DropTarget(context: h.context)
        XCTAssertEqual(drops.operation(sources: [h.url("A")], destination: h.url("A/sub"), modifiers: [], secondary: false), .none)
        XCTAssertEqual(drops.operation(sources: [h.url("A")], destination: h.url("A"), modifiers: .option, secondary: false), .none)
        XCTAssertFalse(drops.run(.none, sources: [h.url("A")], destination: h.url("A/sub"), menuAt: .zero, in: nil))
    }

    func testMenuDropRunsChosenSymlink() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt"); try h.dir("sub")
        let drops = DropTarget(context: h.context)
        drops.presentMenu = { _, _ in .symlink }
        let op = drops.operation(sources: [h.url("a.txt")], destination: h.url("sub"), modifiers: [], secondary: true)
        XCTAssertEqual(op, .menu, "right-drag → drop menu")
        XCTAssertTrue(drops.run(op, sources: [h.url("a.txt")], destination: h.url("sub"), menuAt: .zero, in: NSView()))
        try await h.waitUntil("symlink created") {
            (try? FileManager.default.contentsOfDirectory(atPath: h.url("sub").path))?.isEmpty == false
        }
        let made = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: h.url("sub").path).first)
        let info = try XCTUnwrap(h.lstatInfo("sub/\(made)"))
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFLNK)
        XCTAssertTrue(h.exists("a.txt"), "the source stays")
    }

    func testMenuDropCancelDoesNothing() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt"); try h.dir("sub")
        let drops = DropTarget(context: h.context)
        drops.presentMenu = { _, _ in nil }
        XCTAssertFalse(drops.run(.menu, sources: [h.url("a.txt")], destination: h.url("sub"), menuAt: .zero, in: NSView()))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(h.exists("a.txt"))
        XCTAssertFalse(h.exists("sub/a.txt"))
    }

    func testScenarioDropHookMovesIntoFolder() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt"); try h.dir("sub")
        let browser = try await h.openBrowserWindow()
        await browser.probePerformDrop(sources: [h.url("a.txt")], onto: "sub", modifiers: [], secondary: false, menuChoice: nil)
        try await h.waitUntil("moved by the probe") { h.exists("sub/a.txt") && !h.exists("a.txt") }
    }

    func testScenarioDropSecondaryUsesMenuChoice() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt"); try h.dir("sub")
        let browser = try await h.openBrowserWindow()
        await browser.probePerformDrop(sources: [h.url("a.txt")], onto: "sub", modifiers: [], secondary: true, menuChoice: .copy)
        try await h.waitUntil("copied by the probe") { h.exists("sub/a.txt") }
        XCTAssertTrue(h.exists("a.txt"))
    }

    /// Answers conflicts only after `delay`, like a user looking at the sheet.
    private final class SlowInteraction: FileOpInteraction {
        let inner = ScriptedInteraction(conflicts: [.one(.keepBoth)])
        func resolveConflict(_ conflict: ConflictInfo, job: JobSnapshot) async -> ConflictResolution {
            try? await Task.sleep(for: .seconds(2))
            return await inner.resolveConflict(conflict, job: job)
        }
        func resolveError(_ error: FileOpError, job: JobSnapshot) async -> ErrorResolution { .skip }
        func confirmInsufficientSpace(_ shortfall: SpaceShortfall, job: JobSnapshot) async -> Bool { false }
        func confirmPermanentDeleteWithoutTrash(_ urls: [URL], job: JobSnapshot) async -> Bool { false }
    }

    /// QA round 1: the scenario drop step returns once the job is started, so a later answerConflict step can run.
    func testScenarioDropReturnsWhileTheJobAsksAQuestion() async throws {
        let h = try await ContentTestHarness.make(self)
        try h.file("a.txt"); try h.file("sub/a.txt")
        h.environment.interaction.setTarget(SlowInteraction())
        let browser = try await h.openBrowserWindow()
        let clock = ContinuousClock(), started = clock.now
        await browser.probePerformDrop(sources: [h.url("a.txt")], onto: "sub", modifiers: [], secondary: false, menuChoice: nil)
        XCTAssertLessThan(clock.now - started, .seconds(1), "the drop step did not wait for the conflict answer")
        try await h.waitUntil("kept both", timeout: .seconds(10)) { h.exists("sub/a 2.txt") && !h.exists("a.txt") }
    }
}
