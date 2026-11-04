import Foundation
import MacxFixtures
import MacxFS
import XCTest

final class SortGoldenTests: XCTestCase {
    private func less(_ a: String, _ b: String, folderA: Bool = false, folderB: Bool = false) -> Bool {
        SortKeys.nameKey(a, isFolder: folderA).lexicographicallyPrecedes(SortKeys.nameKey(b, isFolder: folderB))
    }

    func testDigitRunsCompareNumerically() {
        XCTAssertTrue(less("file2", "file10"))
        XCTAssertTrue(less("file9.txt", "file10.txt"))
        XCTAssertTrue(less("v1.9", "v1.10"))
        let big = "x" + String(repeating: "9", count: 254), bigger = "x1" + String(repeating: "0", count: 254)
        XCTAssertTrue(less(big, bigger), "254 nines < 1 followed by 254 zeros")
        XCTAssertTrue(less("a0", "a1"))
        XCTAssertTrue(less("a000", "a1"), "an all-zero run keeps one digit and never collides with the 0x00 separator")
        XCTAssertFalse(SortKeys.nameKey("a000", isFolder: false).dropFirst().prefix(3).contains(0))
    }

    func testLeadingZerosTieBreakOnRunLength() {
        XCTAssertTrue(less("a01", "a2"))
        XCTAssertTrue(less("a001", "a01"), "equal values: more leading zeros first (NFC-byte tie-break)")
        XCTAssertTrue(less("a01", "a1"))
        XCTAssertTrue(less("a1b", "a01c"), "the tie-break never overrides a later difference")
    }

    func testFoldingAndNFCTieBreak() {
        XCTAssertTrue(less("e", "\u{E9}"), "e < é")
        XCTAssertTrue(less("\u{E9}", "f"), "é < f")
        XCTAssertTrue(less("\u{E9}a", "eb"), "diacritics ignored before the tie-break")
        XCTAssertEqual(SortKeys.nameKey("Cafe\u{301}", isFolder: false), SortKeys.nameKey("Caf\u{E9}", isFolder: false),
                       "NFD and NFC spellings get identical keys")
        XCTAssertTrue(less("apple", "Banana"))
        XCTAssertTrue(less("ｆｉｌｅ1", "file2"), "width-insensitive")
    }

    func testFoldersFirstByteAndLayout() {
        XCTAssertTrue(less("zzz", "aaa", folderA: true, folderB: false))
        let key = SortKeys.nameKey("Ab1", isFolder: true)
        XCTAssertEqual(key, [0, 0x61, 0x62, 1, 0x31, 0] + Array("Ab1".utf8))
    }

    /// The ASCII fast path (no CFStringFold for pure-ASCII names, §4.4 key generation) must equal the Foundation
    /// fold for every ASCII byte, alone and inside names, plus the NFC tie-break bytes.
    func testAsciiFoldEqualsFoundationFold() {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        let locale = Locale(identifier: "en_US_POSIX")
        var names = (1..<128).map { String(UnicodeScalar(UInt8($0))) }
        names += (1..<128).map { "Ab\(String(UnicodeScalar(UInt8($0))))Z09.TXT" }
        names += ["IMG_0042.JPG", "Report 2026-11-03.pdf", "README", "a", "ZZ top", "file-000123.txt"]
        for name in names {
            XCTAssertEqual(SortKeys.searchFold(name), Array(name.folding(options: options, locale: locale).utf8), "searchFold \(name.debugDescription)")
            XCTAssertEqual(SortKeys.nameKey(name, isFolder: false), referenceKey(name),
                           "nameKey \(name.debugDescription)")
        }
    }

    /// nameKey built only with Foundation calls (the pre-fast-path algorithm).
    private func referenceKey(_ name: String) -> [UInt8] {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var key: [UInt8] = [1]
        var digits: [UInt8] = []
        func flush() {
            guard !digits.isEmpty else { return }
            var start = 0
            while start < digits.count - 1 && digits[start] == UInt8(ascii: "0") { start += 1 }
            let run = digits[start...].prefix(255)
            key.append(UInt8(run.count))
            key.append(contentsOf: run)
            digits.removeAll()
        }
        for byte in folded.utf8 {
            if byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") { digits.append(byte) } else { flush(); key.append(byte) }
        }
        flush()
        key.append(0)
        key.append(contentsOf: name.precomposedStringWithCanonicalMapping.utf8)
        return key
    }

    func testSearchFold() {
        XCTAssertEqual(SortKeys.searchFold("Résumé"), Array("resume".utf8))
        XCTAssertEqual(SortKeys.searchFold("ＡＢＣ"), Array("abc".utf8))
        XCTAssertEqual(SortKeys.searchFold("file10"), Array("file10".utf8), "no digit encoding")
    }

    func testCorpusIsDeterministicAndLarge() {
        let a = SortCorpus.names(), b = SortCorpus.names()
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 5_000)
        XCTAssertEqual(Set(a).count, 5_000)
    }

    /// §4.2 / §9 golden: our order vs localizedStandardCompare (en_US) on the corpus. Every adjacent pair of the
    /// reference order that our keys invert must be listed, with its category, in Corpus/sort-allowed-divergences.json.
    /// Re-record after an intentional key change or an OS collation change:
    ///   MACX_RECORD_SORT_DIVERGENCES=1 swift test --filter FSKitTests.SortGoldenTests/testCorpusMatchesLocalizedStandardCompareExceptListed
    /// Record mode writes only into a fresh $TMPDIR/macx-tests-* sandbox (kept so the file can be reviewed) and
    /// prints its path; copy it into Tests/FSKitTests/Corpus by hand. It never writes into the source tree.
    func testCorpusMatchesLocalizedStandardCompareExceptListed() throws {
        let actual = sortDivergences(SortCorpus.names())
        XCTAssertFalse(actual.contains { $0.category == DivergenceCategory.other.rawValue },
                       "unexplained: \(actual.filter { $0.category == "other" }.prefix(10))")
        if ProcessInfo.processInfo.environment["MACX_RECORD_SORT_DIVERGENCES"] == "1" {
            let file = DivergenceFile(
                comment: "Generated by SortGoldenTests (record mode). Adjacent pairs (a < b by localizedStandardCompare, en_US) that SortKeys orders b < a.",
                categories: Dictionary(uniqueKeysWithValues: DivergenceCategory.allCases.filter { $0 != .other }.map { ($0.rawValue, $0.reason) }),
                divergences: actual)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let target = try Sandbox().url("sort-allowed-divergences.json")
            try encoder.encode(file).write(to: target)
            let path = target.path(percentEncoded: false)
            print("recorded \(actual.count) divergences to \(path)")
            throw XCTSkip("recorded \(actual.count) divergences to \(path); review, copy into Tests/FSKitTests/Corpus, delete the sandbox")
        }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "sort-allowed-divergences", withExtension: "json", subdirectory: "Corpus"))
        let listed = try JSONDecoder().decode(DivergenceFile.self, from: Data(contentsOf: url))
        let known = Set(listed.divergences), now = Set(actual)
        XCTAssertEqual(now.subtracting(known).sorted { $0.a < $1.a }.prefix(20), [], "new divergences (not listed)")
        XCTAssertEqual(known.subtracting(now).sorted { $0.a < $1.a }.prefix(20), [], "listed divergences that no longer occur")
        for category in Set(listed.divergences.map(\.category)) {
            XCTAssertNotNil(listed.categories[category], "category \(category) needs a reason")
        }
    }
}
