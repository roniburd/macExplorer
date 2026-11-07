// Tests/CoreTests/Search/SearchSpecTests.swift
import XCTest
@testable import Core
@testable import MacxFS

final class SearchSpecTests: XCTestCase {
    let root = URL(filePath: "/tmp/macx-tests-x/root", directoryHint: .isDirectory)
    var cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
    let now = ISO8601DateFormatter().date(from: "2026-11-04T15:00:00Z")!
    let types = TypeRegistry()

    func testURLRoundTripIsLosslessAndDeterministic() {
        let spec = SearchSpec(text: #"report "Q3" size:>1MB"#, scope: .subfolders, mode: .contents,
                              filters: SearchFilters(kinds: [.pdf, .image], extensions: ["pdf"], size: ByteRange(lower: 5),
                                                     modified: .relative(.thisWeek), created: nil), root: root)
        let url = spec.url
        XCTAssertEqual(url.scheme, SearchSpec.urlScheme)
        XCTAssertEqual(SearchSpec(url: url), spec)
        XCTAssertEqual(spec.url, url)                      // sorted keys → same URL every time
        XCTAssertNil(SearchSpec(url: URL(string: "x-macexplorer-search:?v=1&q=%%%")!))
        XCTAssertNil(SearchSpec(url: URL(filePath: "/tmp")))
    }

    func testResolveNameModeMergesSyntaxAndFilters() {
        let spec = SearchSpec(text: "tax kind:pdf,image size:>1KB modified:thismonth", scope: .thisFolder,
                              filters: SearchFilters(kinds: [.pdf], size: ByteRange(upper: 1_000_000), modified: .relative(.today)),
                              root: root)
        let r = SearchResolver.resolve(spec, now: now, calendar: cal)
        XCTAssertEqual(r.criteria.nameTerms, [NameTerm("tax")])
        XCTAssertEqual(r.criteria.kinds, [.pdf, .image])                        // the query's kinds…
        XCTAssertEqual(r.criteria.andKinds, [.pdf])                             // …and the filter's, both required
        XCTAssertEqual(r.criteria.size, ByteRange(lower: 1_001, upper: 1_000_000))
        XCTAssertEqual(r.criteria.modified, DateRanges.range(.relative(.today), now: now, calendar: cal))  // today ⊂ this month
        XCTAssertTrue(r.contentTerms.isEmpty)
        XCTAssertFalse(r.isEmpty)
    }

    func testResolveContentsModeKeepsFreeTermsForContent() {
        let r = SearchResolver.resolve(SearchSpec(text: "invoice name:2025", scope: .subfolders, mode: .contents, root: root),
                                       now: now, calendar: cal)
        XCTAssertEqual(r.contentTerms, ["invoice"])
        XCTAssertEqual(r.criteria.nameTerms, [NameTerm("2025")])
    }

    func testDisjointKindsMatchNothingRatherThanEverything() {
        let r = SearchResolver.resolve(SearchSpec(text: "kind:image", scope: .thisFolder, filters: SearchFilters(kinds: [.pdf]), root: root),
                                       now: now, calendar: cal)
        XCTAssertEqual(r.criteria.kinds, [.image])
        XCTAssertEqual(r.criteria.andKinds, [.pdf])
        var m = CriteriaMatcher(r.criteria, types: types)
        for name in ["a.pdf", "a.png"] { XCTAssertFalse(matches(&m, name), name) }
    }

    private func matches(_ m: inout CriteriaMatcher, _ name: String) -> Bool {
        let e = Entry(rowID: 1, fileID: 1, size: 1, allocSize: 1, mtime: 0, ctime: 0, nameOffset: 0, nameLen: UInt16(name.utf8.count),
                      kind: .file, flags: [], typeIndex: types.index(forExtension: Substring((name as NSString).pathExtension), isDirectory: false))
        return SortKeys.searchFold(name).withUnsafeBytes { m.matches(e, foldedName: $0) }
    }

    /// Search QA: kind:pdf with the Filters panel's Document ticked finds PDFs (a PDF is a document); before, the
    /// labels were intersected (pdf ∩ document = nothing).
    func testQueryKindAndFilterKindCombineByMeaning() {
        let r = SearchResolver.resolve(SearchSpec(text: "kind:pdf", scope: .subfolders, filters: SearchFilters(kinds: [.document]), root: root),
                                       now: now, calendar: cal)
        var m = CriteriaMatcher(r.criteria, types: types)
        XCTAssertTrue(matches(&m, "a.pdf"))
        XCTAssertFalse(matches(&m, "a.txt"))
        XCTAssertFalse(SpotlightPredicate.matchesNothing(r.criteria))
        let same = SearchResolver.resolve(SearchSpec(text: "kind:pdf", scope: .subfolders, filters: SearchFilters(kinds: [.pdf]), root: root),
                                          now: now, calendar: cal)
        XCTAssertEqual(same.criteria.kinds, [.pdf])
        XCTAssertNil(same.criteria.andKinds)
        let filterOnly = SearchResolver.resolve(SearchSpec(text: "x", scope: .subfolders, filters: SearchFilters(kinds: [.document]), root: root),
                                                now: now, calendar: cal)
        XCTAssertEqual(filterOnly.criteria.kinds, [.document])
        XCTAssertNil(filterOnly.criteria.andKinds)
    }

    /// Search QA: kind:banana matches nothing in every engine (in-folder filter, crawler, Spotlight) instead of
    /// being dropped, which widened the search.
    func testUnknownKindMatchesNothing() {
        let r = SearchResolver.resolve(SearchSpec(text: "report kind:banana", scope: .subfolders, root: root), now: now, calendar: cal)
        XCTAssertEqual(r.criteria.kinds, [])
        XCTAssertEqual(r.diagnostics, [SyntaxDiagnostic(token: "kind:banana", problem: .badKind)])
        XCTAssertFalse(r.isEmpty)
        var m = CriteriaMatcher(r.criteria, types: types)
        XCTAssertFalse(matches(&m, "report.pdf"))
        XCTAssertTrue(SpotlightPredicate.matchesNothing(r.criteria))
        let alone = SearchResolver.resolve(SearchSpec(text: "kind:banana", scope: .thisFolder, root: root), now: now, calendar: cal)
        XCTAssertFalse(alone.isEmpty)
        XCTAssertEqual(alone.criteria.kinds, [])
    }

    /// Search QA: the Filters panel's extensions are normalized like ext: ("*.pdf", ".pdf", "pdf").
    func testFilterExtensionsAreNormalizedLikeTheSyntax() {
        let r = SearchResolver.resolve(SearchSpec(text: "x", scope: .subfolders, filters: SearchFilters(extensions: ["*.PDF", ".doc"]), root: root),
                                       now: now, calendar: cal)
        XCTAssertEqual(r.criteria.extensions, ["pdf", "doc"])
    }

    func testEmptyQuery() {
        XCTAssertTrue(SearchSpec(text: "   ", scope: .subfolders, root: root).isEmptyQuery)
        XCTAssertTrue(SearchResolver.resolve(SearchSpec(text: "kind:", scope: .thisFolder, root: root), now: now, calendar: cal).isEmpty)
        XCTAssertFalse(SearchSpec(text: "", scope: .subfolders, filters: SearchFilters(kinds: [.image]), root: root).isEmptyQuery)
    }
    func testURLDoesNotDependOnSetOrder() throws {
        // Sets iterate in per-launch hash order; the encoded form must be sorted so a saved search's URL is stable.
        let spec = SearchSpec(text: "x", scope: .subfolders,
                              filters: SearchFilters(kinds: Set(KindFilter.allCases), extensions: ["zip", "a", "pdf", "m"]), root: root)
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(spec.filters), encoding: .utf8))
        let kinds = KindFilter.allCases.map(\.rawValue).sorted().map { "\"\($0)\"" }.joined(separator: ",")
        XCTAssertTrue(json.contains("[\(kinds)]"), json)
        XCTAssertTrue(json.contains(#"["a","m","pdf","zip"]"#), json)
        XCTAssertEqual(SearchSpec(url: spec.url), spec)
    }
    func testWhitespaceAndNewlineTextIsEmptyQuery() {
        XCTAssertTrue(SearchSpec(text: " \n\t", scope: .subfolders, root: root).isEmptyQuery)
    }
}
