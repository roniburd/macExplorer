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

    /// Spotlight reports the real path (/private/var/..., the on-disk case); the request may carry any spelling.
    func testPostFilterFoldsPrivatePrefixAndCase() async {
        let fake = FakeMetadataQuery(items: [
            item("/private/var/x/a.pdf"), item("/private/var/x/sub/b.pdf"), item("/private/var/x/.h/c.pdf"),
            item("/private/var/xy/out.pdf"),
            item("/Users/Me/Docs/d.pdf"), item("/Users/Me/Docs/sub/e.pdf"),
        ])
        let pdf = SearchCriteria(nameTerms: [NameTerm("*.pdf")])
        let varRoot = URL(filePath: "/var/x", directoryHint: .isDirectory)
        let below = await run(SpotlightRequest(criteria: pdf, contentTerms: [], scope: .folders([varRoot]), within: varRoot), fake)
        XCTAssertEqual(below.batches.flatMap(\.1), ["a.pdf", "b.pdf"])          // .h is hidden below the root
        let direct = await run(SpotlightRequest(criteria: pdf, contentTerms: [], scope: .folders([varRoot]),
                                                directChildrenOf: varRoot), fake)
        XCTAssertEqual(direct.batches.flatMap(\.1), ["a.pdf"])
        let tmpRoot = URL(filePath: "/tmp/q", directoryHint: .isDirectory)
        let tmpFake = FakeMetadataQuery(items: [item("/private/tmp/q/t.pdf"), item("/private/tmp/q/.hid/u.pdf")])
        let tmp = await run(SpotlightRequest(criteria: pdf, contentTerms: [], scope: .folders([tmpRoot]), within: tmpRoot), tmpFake)
        XCTAssertEqual(tmp.batches.flatMap(\.1), ["t.pdf"])
        let mixed = URL(filePath: "/users/me/DOCS", directoryHint: .isDirectory)
        let cased = await run(SpotlightRequest(criteria: pdf, contentTerms: [], scope: .folders([mixed]), within: mixed), fake)
        XCTAssertEqual(cased.batches.flatMap(\.1), ["d.pdf", "e.pdf"])
        let casedDirect = await run(SpotlightRequest(criteria: pdf, contentTerms: [], scope: .folders([mixed]),
                                                     directChildrenOf: mixed), fake)
        XCTAssertEqual(casedDirect.batches.flatMap(\.1), ["d.pdf"])
        // Scope roots alone (Contents over several folders): the hidden check strips the matched root in any spelling.
        let hiddenRoot = FakeMetadataQuery(items: [item("/private/var/.box/f.pdf"), item("/private/var/.box/.g/h.pdf")])
        let box = URL(filePath: "/var/.box", directoryHint: .isDirectory)
        let scoped = await run(SpotlightRequest(criteria: pdf, contentTerms: [], scope: .folders([box])), hiddenRoot)
        XCTAssertEqual(scoped.batches.flatMap(\.1), ["f.pdf"])
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
