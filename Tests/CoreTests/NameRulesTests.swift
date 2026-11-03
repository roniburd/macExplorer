import Core
import Foundation
import MacxFS
import XCTest

/// Rename / new-name rules (§5.6): empty, '/', 255 UTF-8 bytes, NFC/case duplicates, warnings.
final class NameRulesTests: XCTestCase {
    private func validate(_ proposed: String, original: String? = "a.txt", caseSensitive: Bool = false,
                          existing: [String] = ["a.txt", "b.txt"]) -> NameValidation {
        NameRules.validate(proposed, original: original, caseSensitive: caseSensitive) { name in
            existing.contains { NameNormalizer.sameName($0, name, caseSensitive: caseSensitive) }
        }
    }

    func testValidNameHasNoWarnings() {
        XCTAssertEqual(validate("c.txt"), .ok(warnings: []))
    }

    func testEmptyAndSlash() {
        XCTAssertEqual(validate(""), .invalid(.empty))
        XCTAssertEqual(validate("x/y"), .invalid(.containsSlash))
        XCTAssertEqual(validate("/"), .invalid(.containsSlash))
    }

    func testLengthLimitIs255UTF8Bytes() {
        XCTAssertEqual(validate(String(repeating: "n", count: 251) + ".txt"), .ok(warnings: []))
        XCTAssertEqual(validate(String(repeating: "n", count: 252) + ".txt"), .invalid(.tooLong))
        XCTAssertEqual(validate(String(repeating: "\u{65E5}", count: 85), original: nil), .ok(warnings: []), "85 × 3 bytes = 255")
        XCTAssertEqual(validate(String(repeating: "é", count: 128) + ".txt"), .invalid(.tooLong))
        XCTAssertEqual(validate(String(repeating: "e\u{301}", count: 120) + ".txt"), .ok(warnings: []),
                       "measured in NFC: 120 × 2 + 4 bytes")
    }

    func testDuplicateIsCaseInsensitiveOnCaseInsensitiveVolumes() {
        XCTAssertEqual(validate("b.txt"), .invalid(.duplicate))
        XCTAssertEqual(validate("B.TXT"), .invalid(.duplicate))
        XCTAssertEqual(validate("B.TXT", caseSensitive: true), .ok(warnings: []))
        XCTAssertEqual(validate("b.txt", caseSensitive: true), .invalid(.duplicate))
    }

    func testDuplicateIsNormalizationInsensitive() {
        let nfd = "Cafe\u{301}.txt", nfc = "Caf\u{E9}.txt"
        XCTAssertEqual(validate(nfc, existing: [nfd]), .invalid(.duplicate))
        XCTAssertEqual(validate(nfc, caseSensitive: true, existing: [nfd]), .invalid(.duplicate))
    }

    func testCaseOrNormalizationChangeOfOriginalIsNotADuplicate() {
        var asked: [String] = []
        let result = NameRules.validate("A.TXT", original: "a.txt", caseSensitive: false) { asked.append($0); return true }
        XCTAssertEqual(result, .ok(warnings: []))
        XCTAssertEqual(asked, [], "the item itself is not asked about")
        XCTAssertEqual(validate("Cafe\u{301}.txt", original: "Caf\u{E9}.txt", caseSensitive: true,
                                existing: ["Caf\u{E9}.txt"]), .ok(warnings: []))
        XCTAssertEqual(validate("A.txt", original: "a.txt", caseSensitive: true, existing: ["a.txt", "A.txt"]),
                       .invalid(.duplicate), "case-sensitive volume: A.txt is another file")
    }

    func testNewItemDuplicate() {
        XCTAssertEqual(validate("a.txt", original: nil), .invalid(.duplicate))
        XCTAssertEqual(validate("new.txt", original: nil), .ok(warnings: []))
    }

    func testExtensionChangeWarns() {
        XCTAssertEqual(validate("a.md"), .ok(warnings: [.extensionChanged(from: "txt", to: "md")]))
        XCTAssertEqual(validate("a"), .ok(warnings: [.extensionChanged(from: "txt", to: "")]))
        XCTAssertEqual(validate("a.txt.zip"), .ok(warnings: [.extensionChanged(from: "txt", to: "zip")]))
        XCTAssertEqual(validate("plain.rtf", original: "plain"), .ok(warnings: [.extensionChanged(from: "", to: "rtf")]))
        XCTAssertEqual(validate("c.TXT"), .ok(warnings: []), "case-only extension change is not a change")
        XCTAssertEqual(validate("name.", original: "name"), .ok(warnings: []), "a trailing dot is no extension")
        XCTAssertEqual(validate("other.txt", original: nil), .ok(warnings: []), "new items have no extension to change")
    }

    func testLeadingDotWarnsHidden() {
        XCTAssertEqual(validate(".a.txt"), .ok(warnings: [.becomesHidden]))
        XCTAssertEqual(validate(".env", original: nil), .ok(warnings: [.becomesHidden]))
        XCTAssertEqual(validate(".b.txt", original: ".a.txt"), .ok(warnings: []), "already hidden")
        XCTAssertEqual(validate(".config.json", original: "config.txt"),
                       .ok(warnings: [.extensionChanged(from: "txt", to: "json"), .becomesHidden]))
    }

    func testProblemsWinOverWarnings() {
        XCTAssertEqual(validate("b.md", existing: ["a.txt", "b.md"]), .invalid(.duplicate))
        XCTAssertEqual(validate(".x/y"), .invalid(.containsSlash))
    }
}
