import Core
import Foundation
import MacxFS
import XCTest

/// Independent oracle for StoreDiff results: applies the ChangeSet with NSTableView semantics and checks that
/// the old display order becomes the new one, matched by identity (or a declared replacement), with reloads on
/// exactly the changed rows and the minimum number of moves.
enum DiffChecker {
    static func check(old: EntryStore, new: EntryStore, result: DiffResult,
                      file: StaticString = #filePath, line: UInt = #line) {
        let outcome = ChangeSimulator.apply(result.changes, toRowCount: old.visibleCount)
        XCTAssertEqual(outcome.failures, [], "invalid indices", file: file, line: line)
        XCTAssertFalse(outcome.sawReset, "StoreDiff never emits reset", file: file, line: line)
        guard outcome.failures.isEmpty else { return }
        XCTAssertEqual(outcome.rows.count, new.visibleCount, "final row count", file: file, line: line)
        guard outcome.rows.count == new.visibleCount else { return }

        let replaced = Set(result.replacements.map { Pair(old: $0.old, new: $0.new) })
        var used = Set<Int>()
        var removedIDs: [RowID: Int] = [:], insertedIDs: [RowID: Int] = [:]
        var removedNames = Set<String>(), insertedNames = Set<String>()
        var matchedTargets: [(oldRow: Int, newRow: Int)] = []
        for (p, token) in outcome.rows.enumerated() {
            let ni = new.storageIndex(forRow: p)
            guard let r = token else {
                insertedIDs[new.identity(ni), default: 0] += 1
                insertedNames.insert(NameNormalizer.nfc(new.name(ni)))
                XCTAssertFalse(outcome.reloaded.contains(p), "inserted row \(p) is not also reloaded", file: file, line: line)
                continue
            }
            XCTAssertTrue(used.insert(r).inserted, "old row \(r) appears twice", file: file, line: line)
            matchedTargets.append((r, p))
            let oi = old.storageIndex(forRow: r)
            let isReplacement = old.identity(oi) != new.identity(ni)
            if isReplacement {
                XCTAssertTrue(replaced.contains(Pair(old: old.identity(oi), new: new.identity(ni))),
                              "row \(p): \(old.identity(oi)) became \(new.identity(ni)) without a replacement",
                              file: file, line: line)
                XCTAssertEqual(NameNormalizer.nfc(old.name(oi)), NameNormalizer.nfc(new.name(ni)),
                               "replacement keeps the name", file: file, line: line)
            }
            let changed = isReplacement || !sameContent(old, oi, new, ni)
            XCTAssertEqual(outcome.reloaded.contains(p), changed, "reload of final row \(p)", file: file, line: line)
        }
        XCTAssertEqual(replaced.count, result.replacements.count, "replacements are unique", file: file, line: line)
        for r in 0..<old.visibleCount where !used.contains(r) {
            let oi = old.storageIndex(forRow: r)
            removedIDs[old.identity(oi), default: 0] += 1
            removedNames.insert(NameNormalizer.nfc(old.name(oi)))
        }
        XCTAssertTrue(Set(removedIDs.keys).isDisjoint(with: insertedIDs.keys),
                      "an identity was removed and inserted instead of matched", file: file, line: line)
        if old.identityMode == .objectID {
            XCTAssertTrue(removedNames.isDisjoint(with: insertedNames),
                          "same name removed and inserted instead of a replacement: \(removedNames.intersection(insertedNames))",
                          file: file, line: line)
        }
        let moves = result.changes.changes.filter { if case .move = $0 { true } else { false } }.count
        let targets = matchedTargets.sorted { $0.oldRow < $1.oldRow }.map(\.newRow)
        XCTAssertEqual(moves, targets.count - longestIncreasing(targets), "minimal moves", file: file, line: line)
    }

    static func sameContent(_ a: EntryStore, _ ai: UInt32, _ b: EntryStore, _ bi: UInt32) -> Bool {
        var x = a.entry(ai), y = b.entry(bi)
        x.nameOffset = 0
        y.nameOffset = 0
        return x == y && a.name(ai).utf8.elementsEqual(b.name(bi).utf8) && a.errno(ai) == b.errno(bi)
    }

    /// O(n²) reference LIS length.
    static func longestIncreasing(_ values: [Int]) -> Int {
        var best = [Int](repeating: 1, count: values.count)
        for i in values.indices {
            for j in 0..<i where values[j] < values[i] { best[i] = max(best[i], best[j] + 1) }
        }
        return best.max() ?? 0
    }

    private struct Pair: Hashable { var old: RowID; var new: RowID }
}
