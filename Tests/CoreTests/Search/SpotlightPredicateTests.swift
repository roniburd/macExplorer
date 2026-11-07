import XCTest
@testable import Core
@testable import MacxFS

final class SpotlightPredicateTests: XCTestCase {
    func format(_ c: SearchCriteria, contents: [String] = []) -> String {
        SpotlightPredicate.make(SpotlightRequest(criteria: c, contentTerms: contents, scope: .localComputer)).predicateFormat
    }
    func expected(_ format: String, _ args: CVarArg...) -> String { NSPredicate(format: format, argumentArray: args).predicateFormat }

    // Review Focus 1
    func testGlobTermBecomesLikePatternWithoutExtraStars() {
        XCTAssertEqual(format(SearchCriteria(nameTerms: [NameTerm("*.pdf")])), expected("kMDItemFSName LIKE[cd] %@", "*.pdf"))
        XCTAssertEqual(format(SearchCriteria(nameTerms: [NameTerm("report?.doc")])), expected("kMDItemFSName LIKE[cd] %@", "report*.doc"))
        XCTAssertEqual(format(SearchCriteria(nameTerms: [NameTerm("IMG_**")])), expected("kMDItemFSName LIKE[cd] %@", "IMG_*"))
        XCTAssertEqual(format(SearchCriteria(nameTerms: [NameTerm("tax")])), expected("kMDItemFSName LIKE[cd] %@", "*tax*"))
    }

    func testClausesAreANDedInOrder() {
        let c = SearchCriteria(nameTerms: [NameTerm("a")], kinds: [.pdf], extensions: ["pdf"], size: ByteRange(lower: 10, upper: 20))
        XCTAssertEqual(format(c, contents: ["invoice"]),
                       expected("kMDItemFSName LIKE[cd] %@ AND kMDItemTextContent CONTAINS[cd] %@ AND kMDItemContentTypeTree == %@ AND kMDItemFSName LIKE[c] %@ AND kMDItemFSSize >= %@ AND kMDItemFSSize < %@",
                                "*a*", "invoice", "com.adobe.pdf", "*.pdf", NSNumber(value: 10), NSNumber(value: 20)))
    }

    func testKindsAndExtensionsAreORed() {
        let f = format(SearchCriteria(kinds: [.folder, .image], extensions: ["jpg", "png"]))
        XCTAssertEqual(f, expected("(kMDItemContentType == %@ OR kMDItemContentTypeTree == %@) AND (kMDItemFSName LIKE[c] %@ OR kMDItemFSName LIKE[c] %@)",
                                   "public.folder", "public.image", "*.jpg", "*.png"))
    }

    func testEmptySetsMatchNothingAndEmptyRequestMatchesAll() {
        // NSMetadataQuery raises on value predicates (FALSEPREDICATE/TRUEPREDICATE), so "nothing" is an always-false
        // metadata comparison: no file has an empty name.
        XCTAssertEqual(format(SearchCriteria(kinds: [])), expected("kMDItemFSName == %@", ""))
        XCTAssertEqual(format(SearchCriteria(extensions: [])), expected("kMDItemFSName == %@", ""))
        XCTAssertEqual(format(SearchCriteria()), expected("kMDItemFSName LIKE %@", "*"))
        XCTAssertTrue(SpotlightPredicate.matchesNothing(SearchCriteria(kinds: [])))
        XCTAssertTrue(SpotlightPredicate.matchesNothing(SearchCriteria(extensions: [])))
        XCTAssertFalse(SpotlightPredicate.matchesNothing(SearchCriteria(kinds: [.pdf], extensions: ["pdf"])))
        XCTAssertFalse(SpotlightPredicate.matchesNothing(SearchCriteria()))
    }

    func testNeverEmitsValuePredicates() {
        let all = Set(KindFilter.allCases)
        let cases: [SearchCriteria] = [
            SearchCriteria(), SearchCriteria(kinds: []), SearchCriteria(extensions: []),
            SearchCriteria(nameTerms: [NameTerm("a")], kinds: [], extensions: []),
            SearchCriteria(kinds: all), SearchCriteria(kinds: [.folder], extensions: ["x"]),
        ]
        for c in cases {
            for contents in [[], ["invoice"]] {
                let f = format(c, contents: contents)
                XCTAssertFalse(f.contains("TRUEPREDICATE") || f.contains("FALSEPREDICATE"), f)
            }
        }
    }

    func testDatesUseContentChangeAndCreation() {
        let day: Int64 = 86_400_000_000_000
        let p = SpotlightPredicate.make(SpotlightRequest(criteria: SearchCriteria(modified: TimeRange(lower: day), created: TimeRange(upper: 2 * day)),
                                                         contentTerms: [], scope: .localComputer))
        let want = NSPredicate(format: "kMDItemFSContentChangeDate >= %@ AND kMDItemFSCreationDate < %@",
                               Date(timeIntervalSince1970: 86_400) as NSDate, Date(timeIntervalSince1970: 172_800) as NSDate)
        XCTAssertEqual(p.predicateFormat, want.predicateFormat)
    }

    /// Search QA: "?" is widened to "*" for Spotlight (whose LIKE may count folded characters); the post-filter keeps
    /// exactly one character, the same rule as the crawler and the in-folder filter.
    func testQuestionMarkIsPostFilteredNotLiked() {
        XCTAssertEqual(format(SearchCriteria(nameTerms: [NameTerm("stra?e*")])), expected("kMDItemFSName LIKE[cd] %@", "stra*e*"))
    }

    func testAndKindsAddASecondKindClause() {
        XCTAssertEqual(format(SearchCriteria(kinds: [.pdf], andKinds: [.text])),
                       expected("kMDItemContentTypeTree == %@ AND kMDItemContentTypeTree == %@", "com.adobe.pdf", "public.text"))
        XCTAssertTrue(SpotlightPredicate.matchesNothing(SearchCriteria(kinds: [.pdf], andKinds: [])))
    }
}
