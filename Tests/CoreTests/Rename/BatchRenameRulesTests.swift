import XCTest
@testable import Core

final class BatchRenameRulesTests: XCTestCase {
    private func rules(_ edit: (inout BatchRenameRules) -> Void) -> BatchRenameRules { var r = BatchRenameRules(); edit(&r); return r }
    private func u(_ n: String, dir: Bool = false) -> URL { URL(filePath: "/tmp/macx-x/\(n)", directoryHint: dir ? .isDirectory : .notDirectory) }

    func testFindReplaceLiteralAndCase() throws {
        let r = rules { $0.find = "IMG"; $0.replace = "Photo" }
        XCTAssertEqual(try r.apply(to: "img_001 IMG.jpg", index: 0), "Photo_001 Photo.jpg")
        let cs = rules { $0.find = "IMG"; $0.replace = "Photo"; $0.caseSensitive = true }
        XCTAssertEqual(try cs.apply(to: "img_001 IMG.jpg", index: 0), "img_001 Photo.jpg")
    }
    func testRegexTemplateGroupsAndDollarEscape() throws {
        let r = rules { $0.find = #"(\d{4})-(\d{2})-(\d{2})"#; $0.replace = "$3.$2.$1 $$"; $0.useRegex = true }
        XCTAssertEqual(try r.apply(to: "2026-11-01 notes.txt", index: 0), "01.11.2026 $ notes.txt")
        let optional = rules { $0.find = "(a)?b"; $0.replace = "[$1]"; $0.useRegex = true }
        XCTAssertEqual(try optional.apply(to: "b.txt", index: 0), "[].txt")
        let caseless = rules { $0.find = "img"; $0.replace = "P"; $0.useRegex = true }
        XCTAssertEqual(try caseless.apply(to: "IMG_1.jpg", index: 0), "P_1.jpg")
        let trailing = rules { $0.find = "a"; $0.replace = "$"; $0.useRegex = true }
        XCTAssertEqual(try trailing.apply(to: "a.txt", index: 0), "$.txt", "a lone $ at the end is literal")
        let unknownGroup = rules { $0.find = "a"; $0.replace = "$7x"; $0.useRegex = true }
        XCTAssertEqual(try unknownGroup.apply(to: "a.txt", index: 0), "$7x.txt", "a group the pattern doesn't have stays literal")
        XCTAssertThrowsError(try rules { $0.find = "("; $0.useRegex = true }.apply(to: "x", index: 0)) {
            XCTAssertEqual($0 as? BatchRenameRuleError, .invalidPattern("("))
        }
    }
    func testCaseChangesAndScope() throws {
        XCTAssertEqual(try rules { $0.caseChange = .title }.apply(to: "my holiday-photos_raw.JPG", index: 0), "My Holiday-Photos_Raw.JPG")
        XCTAssertEqual(try rules { $0.caseChange = .sentence }.apply(to: "MY FILE.TXT", index: 0), "My file.TXT")
        XCTAssertEqual(try rules { $0.caseChange = .upper }.apply(to: "istanbul.txt", index: 0), "ISTANBUL.txt")
        XCTAssertEqual(try rules { $0.caseChange = .lower; $0.scope = .wholeName }.apply(to: "A.TXT", index: 0), "a.txt")
        XCTAssertEqual(try rules { $0.caseChange = .lower; $0.scope = .extensionOnly }.apply(to: "A.TXT", index: 0), "A.txt")
        XCTAssertEqual(try rules { $0.suffix = "-x" }.apply(to: ".bashrc", index: 0), ".bashrc-x")
        XCTAssertEqual(try rules { $0.suffix = "-x"; $0.scope = .extensionOnly }.apply(to: "README", index: 0), "README")
    }
    func testPrefixSuffixAndNumbering() throws {
        var n = BatchRenameRules.Numbering(); n.start = 9; n.step = 2; n.minDigits = 3
        XCTAssertEqual(try rules { $0.prefix = "x-"; $0.numbering = n }.apply(to: "a.txt", index: 1), "x-a 011.txt")
        n.position = .prefix; n.separator = "_"
        XCTAssertEqual(try rules { $0.numbering = n }.apply(to: "a.txt", index: 0), "009_a.txt")
        var e = BatchRenameRules.Numbering(); e.position = .replaceName; e.baseName = "Trip"
        XCTAssertEqual(try rules { $0.numbering = e }.apply(to: "IMG_4411.HEIC", index: 2), "Trip (3).HEIC")
    }
    func testPreviewStatuses() {
        let urls = [u("a.txt"), u("b.txt"), u("c.txt"), u("d.txt")]
        let r = rules { $0.find = "[ab]"; $0.replace = "z"; $0.useRegex = true }
        let p = BatchRenamePlanner.preview(urls, rules: r, caseSensitive: false,
                                           existingNames: ["a.txt", "b.txt", "c.txt", "d.txt", "e.txt"])
        XCTAssertEqual(p.rows.map(\.status), [.duplicateInBatch, .duplicateInBatch, .unchanged, .unchanged])
        XCTAssertFalse(p.canApply)
        let s = rules { $0.find = "c"; $0.replace = "e" }
        XCTAssertEqual(BatchRenamePlanner.preview([u("c.txt")], rules: s, caseSensitive: false, existingNames: ["c.txt", "E.TXT"]).rows[0].status,
                       .collidesWithExisting("E.TXT"))
        XCTAssertEqual(BatchRenamePlanner.preview([u("c.txt")], rules: s, caseSensitive: true, existingNames: ["c.txt", "E.TXT"]).rows[0].status,
                       .ok, "a case-sensitive volume keeps e.txt and E.TXT apart")
        let slash = rules { $0.replace = "/"; $0.find = "a" }
        XCTAssertEqual(BatchRenamePlanner.preview([u("a.txt")], rules: slash, caseSensitive: false, existingNames: ["a.txt"]).rows[0].status,
                       .invalid(.containsSlash))
        let empty = rules { $0.find = "a.txt"; $0.scope = .wholeName }
        XCTAssertEqual(BatchRenamePlanner.preview([u("a.txt")], rules: empty, caseSensitive: false, existingNames: ["a.txt"]).rows[0].status,
                       .invalid(.empty))
        let ext = rules { $0.find = "txt"; $0.replace = "md"; $0.scope = .wholeName }
        let extRow = BatchRenamePlanner.preview([u("a.txt")], rules: ext, caseSensitive: false, existingNames: ["a.txt"]).rows[0]
        XCTAssertTrue(extRow.extensionChanged)
        XCTAssertEqual(extRow.status, .ok)
        let bad = BatchRenamePlanner.preview([u("a.txt"), u("b.txt")], rules: rules { $0.find = "("; $0.useRegex = true },
                                             caseSensitive: false, existingNames: ["a.txt", "b.txt"])
        XCTAssertEqual(bad.rows.map(\.status), [.invalidPattern("("), .invalidPattern("(")])
        XCTAssertFalse(bad.canApply)
        XCTAssertTrue(BatchRenameStatus.duplicateInBatch.blocksApply)
        XCTAssertFalse(BatchRenameStatus.unchanged.blocksApply)
    }
    func testTakingTheNameOfAnUnchangedBatchItemIsADuplicate() {
        let r = rules { $0.find = "a"; $0.replace = "b" }                // a.txt → b.txt while b.txt stays b.txt
        let p = BatchRenamePlanner.preview([u("a.txt"), u("b.txt")], rules: r, caseSensitive: false, existingNames: ["a.txt", "b.txt"])
        XCTAssertEqual(p.rows.map(\.status), [.duplicateInBatch, .unchanged])
        XCTAssertFalse(p.canApply)
        XCTAssertFalse(BatchRenamePlanner.preview([u("c.txt")], rules: r, caseSensitive: false, existingNames: ["c.txt"]).canApply,
                       "nothing to rename")
    }
    /// QA round 1: search results span folders; the same new name in two different folders is not a duplicate.
    func testSameNewNameInDifferentFoldersIsAllowed() {
        func at(_ path: String) -> URL { URL(filePath: "/tmp/macx-x/\(path)", directoryHint: .notDirectory) }
        let prefixed = BatchRenamePlanner.preview([at("p/x.txt"), at("q/x.txt")], rules: rules { $0.prefix = "new " },
                                                  caseSensitive: false, existingNames: [])
        XCTAssertEqual(prefixed.rows.map(\.status), [.ok, .ok])
        XCTAssertTrue(prefixed.canApply)
        let r = rules { $0.find = "x"; $0.replace = "y" }
        let other = BatchRenamePlanner.preview([at("p/y.txt"), at("q/x.txt")], rules: r, caseSensitive: false, existingNames: [])
        XCTAssertEqual(other.rows.map(\.status), [.unchanged, .ok])
        XCTAssertTrue(other.canApply)
        let same = BatchRenamePlanner.preview([at("p/y.txt"), at("p/x.txt"), at("q/x.txt")], rules: r, caseSensitive: false, existingNames: [])
        XCTAssertEqual(same.rows.map(\.status), [.unchanged, .duplicateInBatch, .ok], "still a duplicate within one folder")
        XCTAssertFalse(same.canApply)
    }
    func testPairsAreTheOKRowsInOrder() {
        let r = rules { $0.find = "a"; $0.replace = "x" }
        let p = BatchRenamePlanner.preview([u("a1.txt"), u("b.txt"), u("a2.txt")], rules: r, caseSensitive: false,
                                           existingNames: ["a1.txt", "b.txt", "a2.txt"])
        XCTAssertTrue(p.canApply)
        XCTAssertEqual(BatchRenamePlanner.pairs(p), [BatchRenamePair(url: u("a1.txt"), newName: "x1.txt"),
                                                     BatchRenamePair(url: u("a2.txt"), newName: "x2.txt")])
    }
    func testSwapAndCaseOnlyPreviewAreOK() {
        var n = BatchRenameRules.Numbering(); n.position = .replaceName; n.baseName = "x"
        let urls = [u("x (2).txt"), u("x (1).txt")]                                   // targets are each other's names
        let p = BatchRenamePlanner.preview(urls, rules: rules { $0.numbering = n }, caseSensitive: false, existingNames: ["x (1).txt", "x (2).txt"])
        XCTAssertEqual(p.rows.map(\.proposed), ["x (1).txt", "x (2).txt"])
        XCTAssertEqual(p.rows.map(\.status), [.ok, .ok])
        let lower = rules { $0.caseChange = .lower }
        XCTAssertEqual(BatchRenamePlanner.preview([u("A.txt")], rules: lower, caseSensitive: false, existingNames: ["A.txt"]).rows[0].status, .ok)
    }
    func testFoldersAreAllBaseName() throws {
        let p = BatchRenamePlanner.preview([u("v1.0", dir: true)], rules: rules { $0.suffix = "-old" }, caseSensitive: false, existingNames: ["v1.0"])
        XCTAssertEqual(p.rows[0].proposed, "v1.0-old")
    }
    func testRulesRoundTripThroughCodable() throws {
        var n = BatchRenameRules.Numbering(); n.position = .prefix; n.minDigits = 2
        let r = rules { $0.find = "a"; $0.replace = "b"; $0.useRegex = true; $0.caseChange = .title; $0.numbering = n; $0.scope = .wholeName }
        XCTAssertEqual(try JSONDecoder().decode(BatchRenameRules.self, from: JSONEncoder().encode(r)), r)
    }
    func testPreviewPerformance10k() {
        let urls = (0..<10_000).map { u("IMG_\($0).jpg") }
        let names = urls.map(\.lastPathComponent)
        var n = BatchRenameRules.Numbering(); n.position = .replaceName; n.baseName = "Trip"
        let r = rules { $0.find = "IMG"; $0.replace = "P"; $0.numbering = n }
        let elapsed = ContinuousClock().measure { _ = BatchRenamePlanner.preview(urls, rules: r, caseSensitive: false, existingNames: names) }
        XCTAssertLessThan(elapsed, .milliseconds(400))      // 100 ms budget × 4 in debug
        let regex = rules { $0.find = #"IMG_(\d+)"#; $0.replace = "P$1"; $0.useRegex = true }
        let regexElapsed = ContinuousClock().measure { _ = BatchRenamePlanner.preview(urls, rules: regex, caseSensitive: false, existingNames: names) }
        XCTAssertLessThan(regexElapsed, .milliseconds(400))
    }
}
