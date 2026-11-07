import XCTest
@testable import MacxFS

final class NamePatternTests: XCTestCase {
    private func m(_ pattern: String, _ name: String) -> Bool {
        let folded = SortKeys.searchFold(name)
        return folded.withUnsafeBytes { NamePattern(pattern).matches($0) }
    }

    func testSubstringIsCaseAndDiacriticInsensitive() {
        XCTAssertTrue(m("resume", "Résumé Final.PDF"))
        XCTAssertTrue(m("FINAL", "Résumé Final.PDF"))
        XCTAssertTrue(m("é", "cafe.txt"))            // the pattern is folded too
        XCTAssertFalse(m("draft", "Résumé Final.PDF"))
        XCTAssertTrue(m("", "anything"))             // empty term matches everything
    }

    // Review Focus 1
    func testGlobTermsMatchWholeName() {
        XCTAssertTrue(m("*.pdf", "a.PDF"))
        XCTAssertFalse(m("*.pdf", "a.pdf.zip"))      // glob is anchored at both ends
        XCTAssertTrue(m("report?.doc", "report1.doc"))
        XCTAssertTrue(m("report?.doc", "reporté.doc"))
        XCTAssertFalse(m("report?.doc", "report12.doc"))
        XCTAssertTrue(m("IMG_*", "img_0001.HEIC"))
        XCTAssertTrue(m("*", "x"))
        XCTAssertTrue(m("*", ""))
        XCTAssertTrue(m("a*b*c", "aXXbYYc"))
        XCTAssertTrue(m("a*b*c", "abc"))
        XCTAssertFalse(m("a*b*c", "acb"))
        XCTAssertTrue(m("**x", "x"))                 // repeated stars collapse
        XCTAssertTrue(m("*.PDF", "résumé.pdf"))
        XCTAssertFalse(m("img_*", "my img_1.jpg"))   // anchored at the start too
        XCTAssertTrue(NamePattern("*.pdf").isGlob)
        XCTAssertFalse(NamePattern("pdf").isGlob)
    }

    func testQuestionMarkMatchesOneMultibyteCharacter() {
        XCTAssertTrue(m("?.txt", "日.txt"))
        XCTAssertFalse(m("?.txt", "日本.txt"))
        XCTAssertTrue(m("??.txt", "日本.txt"))
        XCTAssertTrue(m("?", "😀"))
        XCTAssertFalse(m("?", ""))
        XCTAssertFalse(m("??", "😀"))
    }
}
