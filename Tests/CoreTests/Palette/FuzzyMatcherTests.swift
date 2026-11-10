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

    func testPerformanceUnderTwoMillisecondsForCatalog() {
        let titles = (0..<200).map { "Command number \($0) with some words" }
        let clock = ContinuousClock()
        _ = FuzzyMatcher.match("cnw", in: titles[0])   // warm-up
        let elapsed = clock.measure { for t in titles { _ = FuzzyMatcher.match("cnw", in: t) } }
        XCTAssertLessThan(elapsed, .milliseconds(8))     // 2 ms budget × 4 in debug
    }
}
