// Tests/CoreTests/Search/QuerySyntaxTests.swift
import XCTest
@testable import Core
@testable import MacxFS

final class QuerySyntaxTests: XCTestCase {
    func testFreeTermsAndQuotes() {
        let q = QuerySyntax.parse(#"  budget "Q3 final"  *.xlsx "#)
        XCTAssertEqual(q.freeTerms, ["budget", "Q3 final", "*.xlsx"])
        XCTAssertTrue(q.diagnostics.isEmpty)
    }
    func testNameKindExt() {
        let q = QuerySyntax.parse(#"name:"tax return" kind:pdf,image type:folders ext:.JPG,*.png"#)
        XCTAssertEqual(q.nameTerms, ["tax return"])
        XCTAssertEqual(q.kinds, [.pdf, .image, .folder])
        XCTAssertEqual(q.extensions, ["jpg", "png"])
    }
    func testKeysAreCaseInsensitiveAndUnknownKeysAreLiteral() {
        let q = QuerySyntax.parse("KIND:Image foo:bar \"ext:pdf\" :x")
        XCTAssertEqual(q.kinds, [.image])
        XCTAssertEqual(q.freeTerms, ["foo:bar", "ext:pdf", ":x"])
        XCTAssertTrue(q.extensions.isEmpty)
    }
    func testSizes() {
        XCTAssertEqual(QuerySyntax.parse("size:>10MB").size, ByteRange(lower: 10_000_001))
        XCTAssertEqual(QuerySyntax.parse("size:>=1.5gb").size, ByteRange(lower: 1_500_000_000))
        XCTAssertEqual(QuerySyntax.parse("size:<1KB").size, ByteRange(upper: 1_000))
        XCTAssertEqual(QuerySyntax.parse("size:<=100").size, ByteRange(upper: 101))
        XCTAssertEqual(QuerySyntax.parse("size:=0").size, ByteRange(lower: 0, upper: 1))
        XCTAssertEqual(QuerySyntax.parse("size:1MB..10MB").size, ByteRange(lower: 1_000_000, upper: 10_000_001))
        XCTAssertEqual(QuerySyntax.parse("size:10MB").size, ByteRange(lower: 9_500_000, upper: 10_500_000))
        XCTAssertEqual(QuerySyntax.parse("size:1KiB").size, ByteRange(lower: 512, upper: 1_536))
        XCTAssertEqual(QuerySyntax.parse("size:empty").size, ByteRange(lower: 0, upper: 1))
        XCTAssertEqual(QuerySyntax.parse("size:gigantic").size, ByteRange(lower: 4_000_000_000))
        XCTAssertEqual(QuerySyntax.parse("size:>1MB size:<5MB").size, ByteRange(lower: 1_000_001, upper: 5_000_000))
    }
    func testDates() {
        XCTAssertEqual(QuerySyntax.parse("modified:today").modified, [.relative(.today)])
        XCTAssertEqual(QuerySyntax.parse(#"date:"this week""#).modified, [.relative(.thisWeek)])
        XCTAssertEqual(QuerySyntax.parse("created:LastMonth").created, [.relative(.lastMonth)])
        let d = DayStamp(year: 2026, month: 1, day: 31)
        XCTAssertEqual(QuerySyntax.parse("modified:2026-01-31").modified,
                       [.days(lower: DayBound(day: d, inclusive: true), upper: DayBound(day: d, inclusive: true))])
        XCTAssertEqual(QuerySyntax.parse("modified:>2026-01-31").modified, [.days(lower: DayBound(day: d, inclusive: false), upper: nil)])
        XCTAssertEqual(QuerySyntax.parse("modified:<=2026/01/31").modified, [.days(lower: nil, upper: DayBound(day: d, inclusive: true))])
        let a = DayStamp(year: 2026, month: 1, day: 1)
        XCTAssertEqual(QuerySyntax.parse("modified:2026-01-01..2026-01-31").modified,
                       [.days(lower: DayBound(day: a, inclusive: true), upper: DayBound(day: d, inclusive: true))])
    }
    func testDiagnostics() {
        let q = QuerySyntax.parse("size:big kind:spaceship,image modified:2026-02-30 ext: report")
        XCTAssertEqual(q.diagnostics, [
            SyntaxDiagnostic(token: "size:big", problem: .badSize),
            SyntaxDiagnostic(token: "kind:spaceship,image", problem: .badKind),
            SyntaxDiagnostic(token: "modified:2026-02-30", problem: .badDate),
            SyntaxDiagnostic(token: "ext:", problem: .emptyValue),
        ])
        XCTAssertEqual(q.kinds, [.image])            // known words in a partly bad token still apply
        XCTAssertEqual(q.freeTerms, ["report"])
        XCTAssertNil(q.size)
        XCTAssertTrue(q.modified.isEmpty)
    }
    func testUnbalancedQuoteTakesRestOfText() {
        XCTAssertEqual(QuerySyntax.parse(#"a "b c"#).freeTerms, ["a", "b c"])
    }
    func testHugeSizesAreDiagnosedNotTrapped() {
        let q = QuerySyntax.parse("size:>99999999999999TB size:1e5 size:..5")
        XCTAssertNil(q.size)
        XCTAssertEqual(q.diagnostics.map(\.problem), [.badSize, .badSize, .badSize])
        XCTAssertEqual(QuerySyntax.parse("size:<=4000000TB").size, ByteRange(upper: 4_000_000_000_000_000_001))
    }
    func testWhitespaceOnlyAndNewlines() {
        let q = QuerySyntax.parse("\n\t a\nb ")
        XCTAssertEqual(q.freeTerms, ["a", "b"])
        XCTAssertTrue(QuerySyntax.parse(#""""#).freeTerms.isEmpty)
    }

    /// Search QA: a kind: value with no known word keeps its diagnostic and matches nothing (it never widens).
    func testKindWithNoValidWordMatchesNothing() {
        let q = QuerySyntax.parse("report kind:banana")
        XCTAssertEqual(q.kinds, [])
        XCTAssertEqual(q.diagnostics, [SyntaxDiagnostic(token: "kind:banana", problem: .badKind)])
        XCTAssertNil(QuerySyntax.parse("report").kinds)
        XCTAssertEqual(QuerySyntax.parse("kind:banana kind:pdf").kinds, [.pdf])
    }

    /// Search QA: ext: and the Filters panel's Extension field share one parser.
    func testExtensionListsAcceptStarDotAndSeparators() {
        XCTAssertEqual(QuerySyntax.extensions("*.pdf"), ["pdf"])
        XCTAssertEqual(QuerySyntax.extensions(".PDF, doc;  *.TXT md"), ["pdf", "doc", "txt", "md"])
        XCTAssertEqual(QuerySyntax.extensions(" , *. ."), [])
        XCTAssertEqual(QuerySyntax.parse("ext:*.pdf,.doc").extensions, ["pdf", "doc"])
    }
}
