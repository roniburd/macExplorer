// Tests/CoreTests/Search/SearchSpecTests.swift
import XCTest
@testable import Core
@testable import MacxFS

final class SearchSpecTests: XCTestCase {
    let root = URL(filePath: "/tmp/macx-tests-x/root", directoryHint: .isDirectory)
    var cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
    let now = ISO8601DateFormatter().date(from: "2026-11-04T15:00:00Z")!

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
        XCTAssertEqual(r.criteria.kinds, [.pdf])                                // intersection
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
        XCTAssertEqual(r.criteria.kinds, [])
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
