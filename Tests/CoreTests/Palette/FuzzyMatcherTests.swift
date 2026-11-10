import XCTest
@testable import Core

/// P4-03: the command palette's subsequence scorer.
final class FuzzyMatcherTests: XCTestCase {
    func testSubsequenceAndIndices() {
        XCTAssertEqual(FuzzyMatcher.match("nf", in: "New Folder")?.matchedIndices, [0, 4])
        XCTAssertNotNil(FuzzyMatcher.match("nwfldr", in: "New Folder"))
        XCTAssertNil(FuzzyMatcher.match("xyz", in: "New Folder"))
        XCTAssertNil(FuzzyMatcher.match("folders", in: "Folder"))
        XCTAssertEqual(FuzzyMatcher.match("", in: "Anything")?.score, 0)
        XCTAssertEqual(FuzzyMatcher.match("new folder", in: "New Folder")?.matchedIndices, [0, 1, 2, 4, 5, 6, 7, 8, 9])
    }

    func testCaseDiacriticWidthInsensitive() {
        XCTAssertNotNil(FuzzyMatcher.match("CAFE", in: "Café"))
        XCTAssertNotNil(FuzzyMatcher.match("ｃｏｐｙ", in: "Copy"))
        XCTAssertNotNil(FuzzyMatcher.match("café", in: "CAFE"))
    }

    func testScoresPreferWordStartsAndAcronyms() {
        // c(0)=21; "cp" best second char: Copy p@2 → 21; Copy as Path P@8 word start → 25; Compress p@3 → 20
        XCTAssertEqual(FuzzyMatcher.match("cp", in: "Copy")?.score, 21)
        XCTAssertEqual(FuzzyMatcher.match("cp", in: "Copy as Path")?.score, 25)
        XCTAssertEqual(FuzzyMatcher.match("cp", in: "Compress to .zip")?.score, 20)
        XCTAssertGreaterThan(FuzzyMatcher.match("new", in: "New Folder")!.score,
                             FuzzyMatcher.match("new", in: "Show Package Contents in a New Window")!.score)
    }

    /// A catalog-sized run is correct; its timing (< 2 ms) is macx-bench's `palette.rank`, not a wall-clock
    /// assertion here (unit tests carry no timing budgets on a loaded runner).
    func testMatchesACatalogSizedListOfTitles() {
        let titles = (0..<200).map { "Command number \($0) with some words" }
        let matches = titles.compactMap { FuzzyMatcher.match("cnw", in: $0) }
        XCTAssertEqual(matches.count, titles.count)
        XCTAssertEqual(Set(matches.map(\.matchedIndices.first)), [0], "every match starts at the C of Command")
    }
}
