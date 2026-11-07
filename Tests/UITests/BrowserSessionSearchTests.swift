import XCTest
@testable import UI
@testable import Core
@testable import MacxFS
import MacxFixtures

@MainActor
final class BrowserSessionSearchTests: XCTestCase {
    var sandbox: Sandbox!
    var env: CoreEnvironment!
    var session: BrowserSession!

    override func setUp() async throws {
        sandbox = try Sandbox()
        let s = sandbox!
        addTeardownBlock { s.destroy() }
        try sandbox.createFile("work/tax-2025.pdf")
        try sandbox.createFile("work/Taxes/tax-old.pdf")
        try sandbox.createFile("work/notes.txt")
        env = CoreEnvironment.sandboxed(root: sandbox.root)
        session = BrowserSession(environment: env, initialURL: sandbox.url("work"))
        let shown = session!
        addTeardownBlock { @MainActor in shown.close() }
    }

    var work: URL { sandbox.url("work").standardizedFileURL }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        if condition() { return }
        XCTFail("timed out: \(what)")
    }
    func complete(_ m: SearchResultsModel?) -> Bool { if case .complete? = m?.state { true } else { false } }
    func spec(_ text: String, _ scope: SearchScope = .subfolders, _ mode: SearchMode = .name) -> SearchSpec {
        SearchSpec(text: text, scope: scope, mode: mode, root: work)
    }
    func names(_ m: SearchResultsModel) -> [String] { (0..<m.rowCount).map { m.name(atRow: $0) } }

    func testSubfoldersSearchShowsResultsWithOneHistoryEntry() async throws {
        await session.search(spec("tax"))
        let results = try XCTUnwrap(session.results)
        await waitUntil("complete") { complete(results) }
        XCTAssertEqual(names(results), ["Taxes", "tax-2025.pdf", "tax-old.pdf"])
        XCTAssertEqual(session.history.current, spec("tax").url)
        XCTAssertEqual(session.history.backList.map(\.standardizedFileURL), [work])
        XCTAssertEqual(session.searchSpec, spec("tax"))
    }

    // QA round 1: toggling Show Hidden Files re-runs shown (and parked) crawler results with the new setting.
    func testShowHiddenToggleRerunsShownResults() async throws {
        try sandbox.createFile("work/.tax-dot.txt")
        try sandbox.createFile("work/.dotdir/tax-under-dot.txt")
        env.settings.showHidden = false
        await session.search(spec("tax"))
        let results = try XCTUnwrap(session.results)
        await waitUntil("complete") { complete(results) }
        XCTAssertEqual(names(results), ["Taxes", "tax-2025.pdf", "tax-old.pdf"])
        env.settings.showHidden = true
        await waitUntil("hidden rows appear") { complete(results) && names(results).contains(".tax-dot.txt") }
        XCTAssertEqual(Set(names(results)), ["Taxes", "tax-2025.pdf", "tax-old.pdf", ".tax-dot.txt", "tax-under-dot.txt"])
        XCTAssertTrue(session.results === results)
        env.settings.showHidden = false
        await waitUntil("hidden rows go") { complete(results) && !names(results).contains(".tax-dot.txt") }
        XCTAssertEqual(names(results), ["Taxes", "tax-2025.pdf", "tax-old.pdf"])
    }

    func testParkedResultsFollowShowHiddenWhenShownAgain() async throws {
        try sandbox.createFile("work/.tax-dot.txt")
        env.settings.showHidden = false
        await session.search(spec("tax"))
        let results = try XCTUnwrap(session.results)
        await waitUntil("complete") { complete(results) }
        session.navigate(to: work.appending(path: "Taxes"))
        XCTAssertNil(session.results)
        env.settings.showHidden = true
        try await Task.sleep(for: .milliseconds(50))
        session.goBack()
        XCTAssertTrue(session.results === results)
        await waitUntil("hidden row appears") { complete(results) && names(results).contains(".tax-dot.txt") }
    }

    // Review Focus 5
    func testRetypingReplacesResultsModelAndHistoryEntry() async throws {
        await session.search(spec("ta"))
        let first = try XCTUnwrap(session.results)
        var lateEvents = 0
        await session.search(spec("tax"))
        let token = first.observe { _ in lateEvents += 1 }
        defer { token.cancel() }
        let second = try XCTUnwrap(session.results)
        XCTAssertFalse(first === second)
        XCTAssertEqual(session.history.current, spec("tax").url)
        XCTAssertEqual(session.history.backList.count, 1, "retyping must not grow history")
        await waitUntil("second complete") { complete(second) }
        XCTAssertEqual(lateEvents, 0, "the replaced model is closed")
    }

    func testClearSearchReturnsToTheFolderWithoutAHistoryEntry() async throws {
        await session.search(spec("tax"))
        session.clearSearch()
        XCTAssertNil(session.results)
        XCTAssertNil(session.searchSpec)
        XCTAssertEqual(session.history.current.standardizedFileURL, work)
        XCTAssertFalse(session.history.canGoBack)
    }

    func testThisFolderFilterUsesCriteriaAndNoHistory() async throws {
        await session.search(spec("tax", .thisFolder))
        XCTAssertNil(session.results)
        XCTAssertEqual(session.folder.query.criteria, SearchCriteria(nameTerms: [NameTerm("tax")]))
        XCTAssertFalse(session.history.canGoBack)
        session.navigate(to: sandbox.url("work/Taxes"))
        XCTAssertNil(session.folder.query.criteria, "navigation clears the search")
        XCTAssertNil(session.searchSpec)
    }

    func testOpeningAFolderResultThenBackRestoresTheSameModel() async throws {
        await session.search(spec("tax"))
        let results = try XCTUnwrap(session.results)
        await waitUntil("complete") { complete(results) }
        results.select(.set([1], cursor: 1))
        session.navigate(to: sandbox.url("work/Taxes"))
        XCTAssertNil(session.results)
        session.goBack()
        await waitUntil("restored") { session.results != nil }
        XCTAssertTrue(session.results === results)
        XCTAssertEqual(results.selectedURLs.map(\.lastPathComponent), ["tax-2025.pdf"])
    }

    func testOpenContainingFolderSelectsTheItem() async throws {
        await session.search(spec("tax-old"))
        let results = try XCTUnwrap(session.results)
        await waitUntil("complete") { complete(results) && results.rowCount == 1 }
        session.openContainingFolder(of: results.url(atRow: 0))
        XCTAssertEqual(session.folder.directory.standardizedFileURL, sandbox.url("work/Taxes").standardizedFileURL)
        await waitUntil("selected") { session.folder.selectedURLs.map(\.lastPathComponent) == ["tax-old.pdf"] }
        XCTAssertTrue(session.history.canGoBack)
    }

    func testUpAndReloadWhileShowingResults() async throws {
        await session.search(spec("tax"))
        let results = try XCTUnwrap(session.results)
        await waitUntil("complete") { complete(results) }
        let gen = results.generation
        session.reload()
        XCTAssertGreaterThan(results.generation, gen)
        session.goUp()
        XCTAssertNil(session.results)
        XCTAssertEqual(session.folder.directory.standardizedFileURL, work)
    }

    func testThisMacWithSpotlightOffShowsTheNotice() async throws {
        await session.search(spec("tax", .thisMac))
        let results = try XCTUnwrap(session.results)
        await waitUntil("complete") { complete(results) }
        XCTAssertEqual(results.notices, [.spotlightOff])
        XCTAssertEqual(results.rowCount, 0)
    }

    func testContentsFallbackNoticeOnFolderFilter() async throws {
        await session.search(spec("tax", .thisFolder, .contents))   // sandboxed services report indexing disabled
        XCTAssertNil(session.results)
        XCTAssertEqual(session.lastPlan?.notices, [.contentsNotIndexed(volumeName: env.volumes.volume(for: work)?.name ?? "work")])
    }

    func testExternalResultsParkAndRestore() async throws {
        let model = SearchResultsModel(title: "Red", events: { _ in AsyncStream { $0.yield(.completed(SearchSummary())); $0.finish() } },
                                       context: env.searchContext())
        session.showResults(model, recordHistory: true)
        XCTAssertEqual(session.history.current.scheme, "x-macexplorer-results")
        session.navigate(to: sandbox.url("work/Taxes"))
        session.goBack()
        XCTAssertTrue(session.results === model)
    }
}
