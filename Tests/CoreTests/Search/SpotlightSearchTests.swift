import XCTest
@testable import Core
@testable import MacxFS

final class SpotlightSearchTests: XCTestCase {
    let types = TypeRegistry()
    let gen = Generation.initial.next()

    func item(_ path: String, size: Int64 = 5, tree: [String] = ["public.data", "public.item"], invisible: Bool = false) -> MetadataItem {
        MetadataItem(path: path, name: (path as NSString).lastPathComponent, size: size,
                     modified: Date(timeIntervalSince1970: 1_000), created: Date(timeIntervalSince1970: 500),
                     contentTypeTree: tree, isInvisible: invisible)
    }

    struct Seen { var batches: [(String, [String])] = []; var removed: [[String]] = []; var summary: SearchSummary?; var failure: SearchFailure? }

    func run(_ request: SpotlightRequest, _ fake: FakeMetadataQuery, hidden: Bool = false, limit: Int = SpotlightSearch.resultLimit) async -> Seen {
        var seen = Seen()
        for await e in SpotlightSearch.events(request, query: fake, includeHidden: hidden, generation: gen, types: types, limit: limit) {
            switch e {
            case .batch(let b):
                XCTAssertEqual(b.batch.generation, gen)
                seen.batches.append((SearchResultStore.standardizedParent(b.parent),   // parent URLs are directory URLs (trailing "/"), like the crawler's
                                      (0..<b.batch.count).map { b.batch.name(at: $0) }))
            case .removed(let p): seen.removed.append(p)
            case .completed(let s): seen.summary = s
            case .failed(let f): seen.failure = f
            default: break
            }
        }
        return seen
    }

    func testGroupsByParentAndPostFiltersLikeTheCrawler() async {
        let fake = FakeMetadataQuery(items: [
            item("/r/a/x.pdf"), item("/r/a/y.PDF"), item("/r/b/z.pdf"),
            item("/r/a/x.pdf.zip"),                         // Spotlight LIKE would not return it; the post-filter rejects it anyway
            item("/r/.hid/q.pdf"), item("/r/b/.dot.pdf"), item("/r/b/inv.pdf", invisible: true),
            item("/rx/outside.pdf"),
        ])
        let root = URL(filePath: "/r", directoryHint: .isDirectory)
        let request = SpotlightRequest(criteria: SearchCriteria(nameTerms: [NameTerm("*.pdf")]), contentTerms: [],
                                       scope: .folders([root]), within: root)
        let seen = await run(request, fake)
        XCTAssertEqual(seen.batches.map(\.0), ["/r/a", "/r/b"])
        XCTAssertEqual(seen.batches.map(\.1), [["x.pdf", "y.PDF"], ["z.pdf"]])
        XCTAssertEqual(seen.summary?.resultCount, 3)
        XCTAssertEqual(fake.requests(), [request])
        let shown = await run(request, fake, hidden: true)
        XCTAssertEqual(shown.summary?.resultCount, 6)        // hidden ones too; /rx is still outside `within`
    }

    func testDirectChildrenOnly() async {
        let fake = FakeMetadataQuery(items: [item("/r/a.txt"), item("/r/sub/b.txt")])
        let root = URL(filePath: "/r", directoryHint: .isDirectory)
        let seen = await run(SpotlightRequest(criteria: SearchCriteria(), contentTerms: ["invoice"], scope: .folders([root]),
                                              directChildrenOf: root), fake)
        XCTAssertEqual(seen.batches.flatMap(\.1), ["a.txt"])
    }

    func testUpdatesAndRemovalsAreForwardedAfterCompletion() async {
        let renamed = MetadataItem(path: "/r/a.doc", name: "a.doc", size: 1, modified: nil, created: nil, contentTypeTree: [], isInvisible: false)
        let fake = FakeMetadataQuery(runs: [[
            .init(.added([item("/r/a.pdf"), item("/r/b.pdf")])), .init(.gatheringFinished),
            .init(.updated([item("/r/b.pdf", size: 99)])),
            .init(.updated([renamed])),                       // no longer matches *.pdf → removed
            .init(.removed(["/r/a.pdf"])),
        ]])
        let seen = await run(SpotlightRequest(criteria: SearchCriteria(nameTerms: [NameTerm("*.pdf")]), contentTerms: [], scope: .localComputer), fake)
        XCTAssertEqual(seen.summary?.resultCount, 2)
        XCTAssertEqual(seen.batches.map(\.1), [["a.pdf", "b.pdf"], ["b.pdf"]])
        XCTAssertEqual(seen.removed, [["/r/a.doc"], ["/r/a.pdf"]])
    }

    func testFailureAndLimit() async {
        let failing = await run(SpotlightRequest(criteria: SearchCriteria(), contentTerms: ["x"], scope: .localComputer),
                                FakeMetadataQuery(runs: [[.init(.failed)]]))
        XCTAssertEqual(failing.failure, .spotlightFailed)
        let many = FakeMetadataQuery(items: (0..<5).map { item("/r/f\($0).txt") })
        let limited = await run(SpotlightRequest(criteria: SearchCriteria(), contentTerms: ["x"], scope: .localComputer), many, limit: 3)
        XCTAssertEqual(limited.batches.flatMap(\.1).count, 3)
        XCTAssertEqual(limited.summary?.truncated, true)
    }

    func testEntryConversion() {
        let folder = SpotlightSearch.entry(for: item("/r/Docs", tree: ["public.folder", "public.directory", "public.item"]), types: types)
        XCTAssertEqual(folder.entry.kind, .directory)
        XCTAssertEqual(folder.entry.typeIndex, TypeRegistry.folderIndex)
        XCTAssertEqual(folder.entry.size, 0)
        let app = SpotlightSearch.entry(for: item("/Applications/X.app", tree: ["com.apple.application-bundle", "com.apple.package", "public.directory"]), types: types)
        XCTAssertEqual(app.entry.kind, .package)
        XCTAssertTrue(types.isApplication(app.entry.typeIndex))
        let file = SpotlightSearch.entry(for: item("/r/n.txt", size: 42), types: types)
        XCTAssertEqual(file.name, "n.txt")
        XCTAssertEqual(file.entry.kind, .file)
        XCTAssertEqual(file.entry.size, 42)
        XCTAssertEqual(file.entry.mtime, 1_000_000_000_000)
        XCTAssertEqual(file.entry.ctime, 500_000_000_000)
        XCTAssertNotEqual(file.entry.rowID, SpotlightSearch.entry(for: item("/r/m.txt"), types: types).entry.rowID)
    }

    func testFakeCyclesRunsAndInstallsAtRuntime() async {
        let fake = FakeMetadataQuery(runs: [])
        var events: [MetadataQueryEvent] = []
        for await e in fake.run(SpotlightRequest(criteria: SearchCriteria(), contentTerms: [], scope: .localComputer)) { events.append(e) }
        XCTAssertEqual(events, [.gatheringFinished])
        fake.setRuns([[.init(.added([item("/r/a")])), .init(.gatheringFinished)]])
        events = []
        for await e in fake.run(SpotlightRequest(criteria: SearchCriteria(), contentTerms: [], scope: .localComputer)) { events.append(e) }
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(fake.requests().count, 2)
    }
}
