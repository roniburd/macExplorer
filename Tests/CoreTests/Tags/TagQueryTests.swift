import XCTest
@testable import Core
import MacxFS
import MacxFixtures

/// P4-06: tag queries. Every crawl runs over a fresh `Sandbox`; Spotlight is never started (the predicate builder is
/// pure, and `SpotlightTagQuery`'s cumulative mapping is fed scripted metadata events).
final class TagQueryTests: XCTestCase {
    private var sandbox: Sandbox!
    override func setUpWithError() throws { sandbox = try Sandbox(); let s = sandbox!; addTeardownBlock { s.destroy() } }

    private func tag(_ rel: String, _ names: String...) async throws {
        let u = sandbox.url(rel)
        try await LanePool().perform(on: .unknown) { _ in try TagIO.write(names.map { FileTag(name: $0) }, to: u) }
    }
    private func collect(_ stream: AsyncStream<TagQueryUpdate>) async -> (results: [URL], finished: Bool) {
        var last: [URL] = []; var finished = false
        for await u in stream { switch u { case .results(let r): last = r; case .finished: finished = true } }
        return (last, finished)
    }

    func testCrawlFindsTaggedItemsInsideScopeOnly() async throws {
        try sandbox.createFile("in/a.txt"); try sandbox.createFile("in/deep/b.txt"); try sandbox.createFile("in/c.txt")
        try sandbox.createDirectory("in/Folder"); try sandbox.createFile("out/d.txt")
        try await tag("in/a.txt", "Work"); try await tag("in/deep/b.txt", "work", "Home")
        try await tag("in/Folder", "Work"); try await tag("out/d.txt", "Work")
        let q = CrawlTagQuery(lanes: LanePool())
        let r = await collect(q.results(for: "WORK", scope: .directory(sandbox.url("in"))))
        XCTAssertTrue(r.finished)
        XCTAssertEqual(Set(r.results.map { $0.lastPathComponent }), ["a.txt", "b.txt", "Folder"])
    }

    func testCrawlDoesNotFollowSymlinksOrEnterPackages() async throws {
        try sandbox.createFile("outside/x.txt"); try await tag("outside/x.txt", "T")
        try sandbox.createDirectory("in")
        try sandbox.createSymlink("in/link", target: "../outside")
        try sandbox.createFile("in/App.app/Contents/y.txt"); try await tag("in/App.app/Contents/y.txt", "T")
        let r = await collect(CrawlTagQuery(lanes: LanePool()).results(for: "T", scope: .directory(sandbox.url("in"))))
        XCTAssertEqual(r.results, [])
        XCTAssertTrue(r.finished)
    }

    func testCrawlReportsATaggedPackageButNotItsContents() async throws {
        try sandbox.createFile("in/App.app/Contents/y.txt")
        try await tag("in/App.app", "T"); try await tag("in/App.app/Contents/y.txt", "T")
        let r = await collect(CrawlTagQuery(lanes: LanePool()).results(for: "t", scope: .directory(sandbox.url("in"))))
        XCTAssertEqual(r.results.map(\.lastPathComponent), ["App.app"])
    }

    func testCrawlThisMacFinishesEmpty() async {
        let r = await collect(CrawlTagQuery(lanes: LanePool()).results(for: "T", scope: .thisMac))
        XCTAssertEqual(r.results, []); XCTAssertTrue(r.finished)
    }

    func testCrawlOfAMissingRootFinishesEmpty() async {
        let r = await collect(CrawlTagQuery(lanes: LanePool()).results(for: "T", scope: .directory(sandbox.url("nope"))))
        XCTAssertEqual(r.results, []); XCTAssertTrue(r.finished)
    }

    func testCancellingStopsTheCrawl() async throws {
        try FixtureTree.flat(in: sandbox, at: "big", count: 5_000)
        let stream = CrawlTagQuery(lanes: LanePool()).results(for: "T", scope: .directory(sandbox.url("big")))
        let task = Task { for await _ in stream {} }
        task.cancel()
        let clock = ContinuousClock(); let start = clock.now
        await task.value
        XCTAssertLessThan(clock.now - start, .seconds(2))
    }

    func testSpotlightPredicateIsCaseInsensitiveAndEscapesQuotes() {
        let p = SpotlightTagQuery.predicate(for: #"Bob's "tag""#)
        XCTAssertEqual(p.predicateFormat, #"kMDItemUserTags ==[c] "Bob's \"tag\"""#)
    }

    func testSpotlightScopeMapping() {
        XCTAssertEqual(SpotlightTagQuery.metadataScope(.thisMac), .localComputer)
        let folder = sandbox.url("in")
        XCTAssertEqual(SpotlightTagQuery.metadataScope(.directory(folder)), .folders([folder]))
    }

    /// Scripted metadata events (never Spotlight): additions, changes and removals become cumulative URL lists, and
    /// the end of gathering yields `.finished` once while the query keeps running.
    func testSpotlightResultsAreCumulativeAndFinishOnce() async {
        func item(_ path: String) -> MetadataItem {
            MetadataItem(path: path, name: (path as NSString).lastPathComponent, size: 1, modified: nil, created: nil,
                         contentTypeTree: ["public.data"], isInvisible: false)
        }
        let events: [MetadataQueryEvent] = [.added([item("/x/a"), item("/x/b")]), .gatheringFinished,
                                            .updated([item("/x/c")]), .removed(["/x/a"]), .gatheringFinished]
        let query = SpotlightTagQuery(run: { _, _ in
            AsyncStream { c in for e in events { c.yield(e) }; c.finish() }
        })
        var updates: [TagQueryUpdate] = []
        for await u in query.results(for: "T", scope: .thisMac) { updates.append(u) }
        XCTAssertEqual(updates.filter { $0 == .finished }.count, 1)
        let finishedAt = updates.firstIndex(of: .finished)!
        XCTAssertEqual(updates[..<finishedAt].last, .results([URL(filePath: "/x/a"), URL(filePath: "/x/b")]))
        XCTAssertEqual(updates.last, .results([URL(filePath: "/x/b"), URL(filePath: "/x/c")]))
    }

    func testSpotlightFailureFinishesEmpty() async {
        let query = SpotlightTagQuery(run: { _, _ in AsyncStream { c in c.yield(.failed); c.finish() } })
        var updates: [TagQueryUpdate] = []
        for await u in query.results(for: "T", scope: .thisMac) { updates.append(u) }
        XCTAssertEqual(updates, [.results([]), .finished])
    }
}

/// P4-06 Step 5: cumulative tag-query URL lists become the Phase 3 SearchEvent stream (stat on a lane, a batch per
/// parent folder, removals for URLs that left the set, `completed` on `.finished`).
final class TagSearchEventsTests: XCTestCase {
    private var sandbox: Sandbox!
    override func setUpWithError() throws { sandbox = try Sandbox(); let s = sandbox!; addTeardownBlock { s.destroy() } }

    struct ScriptedQuery: TagQuerying {
        let updates: [TagQueryUpdate]
        func results(for tagName: String, scope: TagScope) -> AsyncStream<TagQueryUpdate> {
            AsyncStream { c in for u in updates { c.yield(u) }; c.finish() }
        }
    }

    @MainActor
    func testFreshURLsBatchPerParentGoneURLsRemovedAndFinishedCompletes() async throws {
        let a = try sandbox.createFile("d1/a.txt"), b = try sandbox.createFile("d1/b.txt")
        let c = try sandbox.createDirectory("d2/C")
        let missing = sandbox.url("d2/missing.txt")
        let query = ScriptedQuery(updates: [.results([a, b]), .results([b, c, missing]), .finished])
        let make = TagSearchEvents.events(query: query, tag: "T", scope: .directory(sandbox.root), lanes: LanePool(),
                                          types: .shared)
        let gen = Generation.initial.next()
        var batches: [(parent: String, names: [String], generation: Generation)] = []
        var removed: [[String]] = []
        var summary: SearchSummary?
        for await event in make(gen) {
            switch event {
            case .batch(let b):
                batches.append((b.parent.lastPathComponent, (0..<b.batch.count).map { b.batch.name(at: $0) }, b.batch.generation))
            case .removed(let paths): removed.append(paths)
            case .completed(let s): summary = s
            case .progress, .notice, .failed: break
            }
        }
        XCTAssertEqual(batches.map(\.parent), ["d1", "d2"])
        XCTAssertEqual(batches.map(\.names), [["a.txt", "b.txt"], ["C"]])
        XCTAssertTrue(batches.allSatisfy { $0.generation == gen })
        XCTAssertEqual(removed.map { $0.map { ($0 as NSString).lastPathComponent } }, [["a.txt"]])
        XCTAssertEqual(summary?.resultCount, 2, "the vanished URL isn't counted")
    }
}

/// P4-06 settings: TAGS section rows and visibility (additive keys).
final class SidebarTagSettingsTests: XCTestCase {
    @MainActor func testSetSidebarTagAppendsHidesCaseInsensitivelyAndPersists() {
        let storage = InMemorySettingsStorage()
        let settings = Settings(storage: storage)
        XCTAssertTrue(settings.showTagsInSidebar)
        settings.setSidebarTag("orange", visible: false)
        XCTAssertEqual(settings.sidebarTags, ["Red", "Yellow", "Green", "Blue", "Purple", "Gray"])
        settings.setSidebarTag("Work", visible: true)
        settings.setSidebarTag("WORK", visible: true)                 // already shown
        settings.setSidebarTag("  ", visible: true)                   // ignored
        XCTAssertEqual(settings.sidebarTags.last, "Work")
        XCTAssertEqual(settings.sidebarTags.count, 7)
        settings.showTagsInSidebar = false
        let reloaded = Settings(storage: storage)
        XCTAssertEqual(reloaded.sidebarTags, settings.sidebarTags)
        XCTAssertFalse(reloaded.showTagsInSidebar)
        XCTAssertEqual(Settings.schemaVersion, 3, "Phase 4 settings are additive")
    }
}
