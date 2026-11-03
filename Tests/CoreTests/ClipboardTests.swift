import AppKit
import Foundation
import MacxFS
import XCTest
@testable import Core

private func u(_ path: String) -> URL { URL(filePath: path, directoryHint: .notDirectory) }
private func d(_ path: String) -> URL { URL(filePath: path, directoryHint: .isDirectory) }

@MainActor
final class InMemoryPasteboardTests: XCTestCase {
    func testStartsEmpty() {
        let board = InMemoryPasteboard()
        XCTAssertEqual(board.changeCount, 0)
        XCTAssertFalse(board.hasFileURLs())
        XCTAssertFalse(board.hasCutMarker())
        XCTAssertEqual(board.readFileURLs(), [])
    }

    func testWriteBumpsChangeCountAndStoresMarker() {
        let board = InMemoryPasteboard()
        let first = board.writeFileURLs([u("/tmp/a"), u("/tmp/b")], cutMarker: true)
        XCTAssertEqual(first, board.changeCount)
        XCTAssertEqual(board.readFileURLs(), [u("/tmp/a"), u("/tmp/b")])
        XCTAssertTrue(board.hasFileURLs())
        XCTAssertTrue(board.hasCutMarker())
        let second = board.writeFileURLs([u("/tmp/c")], cutMarker: false)
        XCTAssertGreaterThan(second, first)
        XCTAssertFalse(board.hasCutMarker())
        XCTAssertEqual(board.readFileURLs(), [u("/tmp/c")])
    }

    func testSimulateExternalCopyBumpsCountWithoutMarker() {
        let board = InMemoryPasteboard()
        board.writeFileURLs([u("/tmp/a")], cutMarker: true)
        let before = board.changeCount
        board.simulateExternalCopy([u("/tmp/x")])
        XCTAssertGreaterThan(board.changeCount, before)
        XCTAssertFalse(board.hasCutMarker())
        XCTAssertEqual(board.readFileURLs(), [u("/tmp/x")])
    }
}

@MainActor
final class ClipboardTests: XCTestCase {
    private var board: InMemoryPasteboard!
    private var clipboard: Clipboard!

    override func setUp() async throws {
        board = InMemoryPasteboard()
        clipboard = Clipboard(backend: board)
    }

    func testBackendIsExposed() {
        XCTAssertTrue(clipboard.backend === board)
    }

    func testCopyWritesURLsWithoutMarker() {
        clipboard.copy([u("/w/a.txt"), u("/w/b.txt")])
        XCTAssertEqual(board.readFileURLs(), [u("/w/a.txt"), u("/w/b.txt")])
        XCTAssertFalse(board.hasCutMarker())
        XCTAssertTrue(clipboard.cutURLs.isEmpty)
        XCTAssertTrue(clipboard.canPaste)
    }

    func testCutWritesMarkerAndRemembersURLs() {
        clipboard.cut([u("/w/a.txt"), u("/w/sub/b.txt")])
        XCTAssertTrue(board.hasCutMarker())
        XCTAssertEqual(board.readFileURLs(), [u("/w/a.txt"), u("/w/sub/b.txt")])
        XCTAssertEqual(clipboard.cutURLs, [u("/w/a.txt"), u("/w/sub/b.txt")])
    }

    func testCutNamesOnlyForDirectChildren() {
        clipboard.cut([u("/w/a.txt"), u("/w/sub/b.txt"), d("/w/folder")])
        XCTAssertEqual(clipboard.cutNames(in: d("/w")), ["a.txt", "folder"])
        XCTAssertEqual(clipboard.cutNames(in: u("/w/")), ["a.txt", "folder"], "trailing slash irrelevant")
        XCTAssertEqual(clipboard.cutNames(in: d("/w/sub")), ["b.txt"])
        XCTAssertEqual(clipboard.cutNames(in: d("/other")), [])
    }

    func testCutNamesTreatPrivateVarAsVar() {
        clipboard.cut([u("/private/var/folders/x/a.txt")])
        XCTAssertEqual(clipboard.cutNames(in: d("/var/folders/x")), ["a.txt"])
        clipboard.cut([u("/var/folders/x/b.txt")])
        XCTAssertEqual(clipboard.cutNames(in: d("/private/var/folders/x")), ["b.txt"])
    }

    func testCutNamesKeepUnicodeNamesAsIs() {
        let nfd = "Cafe\u{301}.txt"
        clipboard.cut([u("/w/" + nfd)])
        let names = clipboard.cutNames(in: d("/w"))
        XCTAssertEqual(names.count, 1)
        XCTAssertEqual(names.first?.unicodeScalars.count, nfd.unicodeScalars.count)
    }

    func testCopyAfterCutClearsCut() {
        clipboard.cut([u("/w/a.txt")])
        clipboard.copy([u("/w/b.txt")])
        XCTAssertTrue(clipboard.cutURLs.isEmpty)
        XCTAssertFalse(board.hasCutMarker())
        XCTAssertEqual(clipboard.pastePlan(into: d("/dst"), moveItemHere: false)?.operation, .copy)
    }

    func testStaleMarkerPastesAsCopy() throws {
        clipboard.cut([u("/w/a.txt")])
        board.simulateExternalCopy([u("/w/a.txt")])
        XCTAssertTrue(clipboard.cutURLs.isEmpty, "changeCount moved on: invalid even before revalidate")
        clipboard.revalidate()
        XCTAssertTrue(clipboard.cutURLs.isEmpty)
        XCTAssertEqual(clipboard.cutNames(in: d("/w")), [])
        let plan = try XCTUnwrap(clipboard.pastePlan(into: d("/dst"), moveItemHere: false))
        XCTAssertEqual(plan.operation, .copy)
        XCTAssertFalse(plan.isNoOp)
    }

    func testMarkerFromAnotherProcessOrRelaunchPastesAsCopy() throws {
        // A previous run (or another macExplorer process) left the marker; this Clipboard never cut anything.
        board.writeFileURLs([u("/w/a.txt")], cutMarker: true)
        let fresh = Clipboard(backend: board)
        XCTAssertTrue(fresh.cutURLs.isEmpty)
        let plan = try XCTUnwrap(fresh.pastePlan(into: d("/dst"), moveItemHere: false))
        XCTAssertEqual(plan.operation, .copy)
    }

    func testValidCutPastesAsMoveAndDidPasteClears() throws {
        clipboard.cut([u("/w/a.txt"), u("/w/b.txt")])
        let plan = try XCTUnwrap(clipboard.pastePlan(into: d("/dst"), moveItemHere: false))
        XCTAssertEqual(plan, PastePlan(sources: [u("/w/a.txt"), u("/w/b.txt")], destination: d("/dst"),
                                       operation: .move, isNoOp: false))
        XCTAssertFalse(clipboard.cutURLs.isEmpty, "planning alone does not clear")
        clipboard.didPaste(plan)
        XCTAssertTrue(clipboard.cutURLs.isEmpty)
        XCTAssertEqual(clipboard.pastePlan(into: d("/dst"), moveItemHere: false)?.operation, .copy,
                       "a second paste after the move never moves again")
    }

    func testDidPasteOfCopyKeepsCut() throws {
        clipboard.copy([u("/w/a.txt")])
        let plan = try XCTUnwrap(clipboard.pastePlan(into: d("/dst"), moveItemHere: false))
        clipboard.cut([u("/w/b.txt")])
        clipboard.didPaste(plan)
        XCTAssertEqual(clipboard.cutURLs, [u("/w/b.txt")], "a finished copy does not clear a newer cut")
    }

    func testCutPasteIntoOwnFolderIsNoOp() throws {
        clipboard.cut([u("/w/a.txt"), u("/w/b.txt")])
        let plan = try XCTUnwrap(clipboard.pastePlan(into: d("/w"), moveItemHere: false))
        XCTAssertTrue(plan.isNoOp)
        XCTAssertEqual(plan.operation, .move)
        clipboard.didPaste(plan)
        XCTAssertTrue(clipboard.cutURLs.isEmpty, "no-op cut-paste clears the cut state")
    }

    func testCutPasteIntoOwnFolderViaPrivateSpellingIsNoOp() throws {
        clipboard.cut([u("/private/var/folders/x/a.txt")])
        XCTAssertEqual(clipboard.pastePlan(into: d("/var/folders/x"), moveItemHere: false)?.isNoOp, true)
    }

    func testCutFromMixedFoldersIntoOneOfThemIsNotNoOp() throws {
        clipboard.cut([u("/w/a.txt"), u("/w/sub/b.txt")])
        let plan = try XCTUnwrap(clipboard.pastePlan(into: d("/w"), moveItemHere: false))
        XCTAssertFalse(plan.isNoOp)
        XCTAssertEqual(plan.operation, .move)
    }

    func testCopyPasteIntoSameFolderIsNotNoOp() throws {
        clipboard.copy([u("/w/a.txt")])
        let plan = try XCTUnwrap(clipboard.pastePlan(into: d("/w"), moveItemHere: false))
        XCTAssertFalse(plan.isNoOp, "copy into the same folder makes Finder-style copies")
        XCTAssertEqual(plan.operation, .copy)
    }

    func testMoveItemHereMovesExternalCopy() throws {
        board.simulateExternalCopy([u("/w/a.txt")])
        let plan = try XCTUnwrap(clipboard.pastePlan(into: d("/dst"), moveItemHere: true))
        XCTAssertEqual(plan.operation, .move)
        XCTAssertEqual(plan.sources, [u("/w/a.txt")])
        XCTAssertEqual(clipboard.pastePlan(into: d("/dst"), moveItemHere: false)?.operation, .copy,
                       "plain paste of Finder-copied URLs copies")
    }

    func testPastePlanNilWhenNothingPasteable() {
        XCTAssertFalse(clipboard.canPaste)
        XCTAssertNil(clipboard.pastePlan(into: d("/dst"), moveItemHere: false))
        XCTAssertNil(clipboard.pastePlan(into: d("/dst"), moveItemHere: true))
    }

    func testEscapeRewritesURLsWithoutMarker() throws {
        clipboard.cut([u("/w/a.txt"), u("/w/b.txt")])
        clipboard.clearCut()
        XCTAssertFalse(board.hasCutMarker())
        XCTAssertEqual(board.readFileURLs(), [u("/w/a.txt"), u("/w/b.txt")], "URLs kept, order kept")
        XCTAssertTrue(clipboard.cutURLs.isEmpty)
        XCTAssertEqual(clipboard.pastePlan(into: d("/dst"), moveItemHere: false)?.operation, .copy)
    }

    func testEscapeWithoutOwnCutLeavesPasteboardAlone() {
        board.simulateExternalCopy([u("/w/a.txt")])
        let count = board.changeCount
        clipboard.clearCut()
        XCTAssertEqual(board.changeCount, count, "Esc never rewrites another app's clipboard")
        XCTAssertEqual(board.readFileURLs(), [u("/w/a.txt")])
    }

    func testEmptyCopyOrCutIsIgnored() {
        clipboard.copy([u("/w/a.txt")])
        let count = board.changeCount
        clipboard.cut([])
        clipboard.copy([])
        XCTAssertEqual(board.changeCount, count)
        XCTAssertEqual(board.readFileURLs(), [u("/w/a.txt")])
    }

    func testObserversFireWhenCutSetChanges() {
        var calls = 0
        let token = clipboard.observe { calls += 1 }
        clipboard.cut([u("/w/a.txt")])
        XCTAssertEqual(calls, 1)
        clipboard.revalidate()
        XCTAssertEqual(calls, 1, "revalidate with nothing changed is silent")
        board.simulateExternalCopy([u("/w/x")])
        clipboard.revalidate()
        XCTAssertEqual(calls, 2, "stale marker detected")
        clipboard.revalidate()
        XCTAssertEqual(calls, 2)
        clipboard.cut([u("/w/a.txt")])
        clipboard.clearCut()
        XCTAssertEqual(calls, 4)
        clipboard.cut([u("/w/a.txt")])
        clipboard.copy([u("/w/b.txt")])
        XCTAssertEqual(calls, 6)
        clipboard.copy([u("/w/c.txt")])
        XCTAssertEqual(calls, 6, "copy with no cut pending is silent")
        clipboard.cut([u("/w/a.txt")])
        let plan = clipboard.pastePlan(into: d("/dst"), moveItemHere: false)!
        clipboard.didPaste(plan)
        XCTAssertEqual(calls, 8)
        token.cancel()
        clipboard.cut([u("/w/a.txt")])
        XCTAssertEqual(calls, 8)
    }
}

/// SystemPasteboard against a private, uniquely named NSPasteboard (never .general).
@MainActor
final class SystemPasteboardTests: XCTestCase {
    private var boardName = ""
    private var board: SystemPasteboard!

    override func setUp() async throws {
        boardName = "macx-tests-\(UUID().uuidString)"
        board = SystemPasteboard(name: boardName)
        let captured = boardName
        addTeardownBlock { @MainActor in NSPasteboard(name: NSPasteboard.Name(captured)).releaseGlobally() }
    }

    private var raw: NSPasteboard { NSPasteboard(name: NSPasteboard.Name(boardName)) }

    func testCutMarkerTypeName() {
        XCTAssertEqual(SystemPasteboard.cutMarkerType, "com.macexplorer.cut")
    }

    func testWritesOneFileURLItemPerURLPlusLegacyAndText() throws {
        let urls = [u("/tmp/macx/a.txt"), d("/tmp/macx/dir"), u("/tmp/macx/Cafe\u{301} #1.txt")]
        let count = board.writeFileURLs(urls, cutMarker: false)
        XCTAssertEqual(count, raw.changeCount)
        XCTAssertEqual(board.changeCount, raw.changeCount)
        let items = try XCTUnwrap(raw.pasteboardItems)
        XCTAssertEqual(items.count, 3)
        for (item, url) in zip(items, urls) {
            XCTAssertEqual(item.string(forType: .fileURL).flatMap(URL.init(string:))?.path(percentEncoded: false),
                           url.path(percentEncoded: false))
        }
        // Legacy list and text carry plain POSIX paths, without the directory URL's trailing slash.
        let legacy = raw.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String]
        let paths = ["/tmp/macx/a.txt", "/tmp/macx/dir", "/tmp/macx/Cafe\u{301} #1.txt"]
        XCTAssertEqual(legacy.map { $0.map { Array($0.utf8) } }, paths.map { Array($0.utf8) })
        XCTAssertEqual(raw.string(forType: .string).map { Array($0.utf8) }, Array(paths.joined(separator: "\n").utf8))
        XCTAssertFalse(board.hasCutMarker())
        XCTAssertTrue(board.hasFileURLs())
    }

    func testOtherAppsReadTheURLsViaNSURL() throws {
        let urls = [u("/tmp/macx/a.txt"), u("/tmp/macx/b.txt")]
        board.writeFileURLs(urls, cutMarker: true)
        let read = raw.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        XCTAssertEqual(read?.map { $0.path(percentEncoded: false) }, urls.map { $0.path(percentEncoded: false) })
    }

    func testRoundTripAndMarker() {
        let urls = [u("/tmp/macx/a.txt"), d("/tmp/macx/sub")]
        board.writeFileURLs(urls, cutMarker: true)
        XCTAssertTrue(board.hasCutMarker())
        XCTAssertEqual(board.readFileURLs().map { $0.path(percentEncoded: false) },
                       urls.map { $0.path(percentEncoded: false) })
        let before = board.changeCount
        board.writeFileURLs(urls, cutMarker: false)
        XCTAssertNotEqual(board.changeCount, before)
        XCTAssertFalse(board.hasCutMarker())
    }

    func testExternalWriteChangesCountAndDropsMarker() {
        board.writeFileURLs([u("/tmp/macx/a.txt")], cutMarker: true)
        let before = board.changeCount
        raw.clearContents()
        raw.setString("hello", forType: .string)
        XCTAssertNotEqual(board.changeCount, before)
        XCTAssertFalse(board.hasCutMarker())
        XCTAssertFalse(board.hasFileURLs())
        XCTAssertEqual(board.readFileURLs(), [])
    }

    func testReadsLegacyFilenamesOnly() {
        raw.clearContents()
        raw.setPropertyList(["/tmp/macx/a.txt", "/tmp/macx/b.txt"], forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))
        XCTAssertTrue(board.hasFileURLs())
        XCTAssertEqual(board.readFileURLs().map { $0.path(percentEncoded: false) }, ["/tmp/macx/a.txt", "/tmp/macx/b.txt"])
    }

    func testClipboardStaleAndEscapeOnSystemPasteboard() throws {
        let clipboard = Clipboard(backend: board)
        clipboard.cut([u("/tmp/macx/a.txt")])
        XCTAssertEqual(clipboard.pastePlan(into: d("/tmp/macx/dst"), moveItemHere: false)?.operation, .move)
        clipboard.clearCut()
        XCTAssertFalse(board.hasCutMarker())
        XCTAssertTrue(board.hasFileURLs())
        clipboard.cut([u("/tmp/macx/a.txt")])
        raw.clearContents()
        raw.writeObjects([u("/tmp/macx/a.txt") as NSURL])   // "Finder copied a.txt"
        clipboard.revalidate()
        XCTAssertTrue(clipboard.cutURLs.isEmpty)
        XCTAssertEqual(clipboard.pastePlan(into: d("/tmp/macx/dst"), moveItemHere: false)?.operation, .copy)
    }

    func testWrites100kURLsWithoutCap() {
        let urls = (0..<100_000).map { u("/tmp/macx-bench/f\($0).txt") }
        let start = ContinuousClock.now
        board.writeFileURLs(urls, cutMarker: true)
        let elapsed = ContinuousClock.now - start
        XCTAssertEqual(raw.pasteboardItems?.count, 100_000)
        XCTAssertTrue(board.hasCutMarker())
        // The pasteboard server costs ~100 µs per public.file-url item on an M3 Pro (writeObjects of 100k NSURLs alone takes
        // ~10 s), so this is only a no-cap sanity bound; macx-bench measures the real cost against the §4.4 budget.
        XCTAssertLessThan(elapsed, .seconds(60))
    }
}
