import Core
import Foundation
import MacxFS
import XCTest

final class StoreDiffTests: XCTestCase {
    private func diff(_ old: EntryStore, _ new: EntryStore, file: StaticString = #filePath, line: UInt = #line) -> DiffResult {
        let result = StoreDiff.diff(old: old, new: new)
        DiffChecker.check(old: old, new: new, result: result, file: file, line: line)
        return result
    }

    private let abc = [Row(1, "a"), Row(2, "b"), Row(3, "c")]

    // MARK: identity

    func testIdenticalStoresProduceNoChanges() {
        let r = diff(StoreBuilder.store(abc), StoreBuilder.store(abc))
        XCTAssertTrue(r.changes.isEmpty)
        XCTAssertEqual(r.changes.changes, [])
        XCTAssertEqual(r.replacements, [])
    }

    func testEmptyStores() {
        XCTAssertEqual(diff(StoreBuilder.store([]), StoreBuilder.store([])).changes, ChangeSet([]))
        XCTAssertEqual(diff(StoreBuilder.store([]), StoreBuilder.store(abc)).changes, ChangeSet([.insert(IndexSet(0..<3))]))
        XCTAssertEqual(diff(StoreBuilder.store(abc), StoreBuilder.store([])).changes, ChangeSet([.remove(IndexSet(0..<3))]))
    }

    func testInsertUsesFinalIndices() {
        let new = StoreBuilder.store([Row(1, "a"), Row(4, "ab"), Row(2, "b"), Row(3, "c"), Row(5, "d")])
        XCTAssertEqual(diff(StoreBuilder.store(abc), new).changes, ChangeSet([.insert(IndexSet([1, 4]))]))
    }

    func testRemoveUsesOldIndices() {
        let old = StoreBuilder.store([Row(1, "a"), Row(2, "b"), Row(3, "c"), Row(4, "d")])
        XCTAssertEqual(diff(old, StoreBuilder.store([Row(1, "a"), Row(3, "c")])).changes, ChangeSet([.remove(IndexSet([1, 3]))]))
    }

    func testMatchesByIdentityNotStoragePosition() {
        // Same rows, different storage order, same display order: nothing changed.
        let old = StoreBuilder.store(abc)
        let new = StoreBuilder.store([Row(3, "c"), Row(1, "a"), Row(2, "b")], order: [1, 2, 0])
        XCTAssertTrue(diff(old, new).changes.isEmpty)
    }

    // MARK: reload

    func testChangedMtimeOrSizeReloadsAtFinalIndex() {
        let new = StoreBuilder.store([Row(1, "a"), Row(2, "b", mtime: 5), Row(3, "c", size: 9)])
        XCTAssertEqual(diff(StoreBuilder.store(abc), new).changes, ChangeSet([.reload(IndexSet([1, 2]))]))
    }

    func testReloadIndicesAreFinalAfterRemoveAndInsert() {
        let new = StoreBuilder.store([Row(9, "0"), Row(2, "b", mtime: 7), Row(3, "c")])
        XCTAssertEqual(diff(StoreBuilder.store(abc), new).changes,
                       ChangeSet([.remove(IndexSet(integer: 0)), .insert(IndexSet(integer: 0)), .reload(IndexSet(integer: 1))]))
    }

    func testRenameInPlaceReloadsWithoutMove() {
        let new = StoreBuilder.store([Row(1, "a"), Row(2, "bb"), Row(3, "c")])
        XCTAssertEqual(diff(StoreBuilder.store(abc), new).changes, ChangeSet([.reload(IndexSet(integer: 1))]))
    }

    func testRenameThatChangesSortedPositionReloadsAndMoves() {
        let new = StoreBuilder.store([Row(2, "b"), Row(3, "c"), Row(1, "d")])
        XCTAssertEqual(diff(StoreBuilder.store(abc), new).changes,
                       ChangeSet([.move(from: 0, to: 2), .reload(IndexSet(integer: 2))]))
    }

    func testErrnoChangeReloads() {
        var new = StoreBuilder.store(abc)
        new.setError(13, at: 1)
        XCTAssertEqual(diff(StoreBuilder.store(abc), new).changes, ChangeSet([.reload(IndexSet(integer: 1))]))
    }

    // MARK: replacement (atomic save)

    func testAtomicSaveIsReplacementWithReload() {
        let old = StoreBuilder.store([Row(1, "a.txt"), Row(2, "b.txt", mtime: 1)])
        let new = StoreBuilder.store([Row(1, "a.txt"), Row(9, "b.txt", mtime: 2)])
        let r = diff(old, new)
        XCTAssertEqual(r.changes, ChangeSet([.reload(IndexSet(integer: 1))]))
        XCTAssertEqual(r.replacements, [Replacement(old: .object(2), new: .object(9))])
    }

    func testReplacementIsNotTriggeredByDifferentNames() {
        let r = diff(StoreBuilder.store([Row(1, "a"), Row(2, "b")]), StoreBuilder.store([Row(1, "a"), Row(9, "c")]))
        XCTAssertEqual(r.changes, ChangeSet([.remove(IndexSet(integer: 1)), .insert(IndexSet(integer: 1))]))
        XCTAssertEqual(r.replacements, [])
    }

    func testReplacementMatchesNormalizedNames() {
        let nfd = "e\u{301}.txt", nfc = "\u{e9}.txt"
        let r = diff(StoreBuilder.store([Row(1, nfd)]), StoreBuilder.store([Row(2, nfc)]))
        XCTAssertEqual(r.replacements, [Replacement(old: .object(1), new: .object(2))])
        XCTAssertEqual(r.changes, ChangeSet([.reload(IndexSet(integer: 0))]))
    }

    func testReplacementThatMovesInDateOrder() {
        // Date-modified order: the saved file becomes newest and moves to the end.
        let old = StoreBuilder.store([Row(2, "b", mtime: 1), Row(1, "a", mtime: 2), Row(3, "c", mtime: 3)])
        let new = StoreBuilder.store([Row(1, "a", mtime: 2), Row(3, "c", mtime: 3), Row(9, "b", mtime: 4)])
        let r = diff(old, new)
        XCTAssertEqual(r.changes, ChangeSet([.move(from: 0, to: 2), .reload(IndexSet(integer: 2))]))
        XCTAssertEqual(r.replacements, [Replacement(old: .object(2), new: .object(9))])
    }

    func testMatchedIdentityWinsOverReplacement() {
        // 2 kept its identity (renamed to "x"); 9 took the name "b": that is an insert, not a replacement of 2.
        let old = StoreBuilder.store([Row(1, "a"), Row(2, "b")])
        let new = StoreBuilder.store([Row(1, "a"), Row(9, "b"), Row(2, "x")])
        let r = diff(old, new)
        XCTAssertEqual(r.replacements, [])
        XCTAssertEqual(r.changes, ChangeSet([.insert(IndexSet(integer: 1)), .reload(IndexSet(integer: 2))]))
    }

    func testDuplicateNamesAmongReplacementCandidatesPairOnce() {
        let old = StoreBuilder.store([Row(1, "a"), Row(2, "a")])
        let new = StoreBuilder.store([Row(9, "a")])
        let r = diff(old, new)
        XCTAssertEqual(r.replacements.count, 1)
        XCTAssertEqual(r.replacements.first?.new, .object(9))
    }

    // MARK: moves

    func testRotationIsOneMove() {
        let old = StoreBuilder.store([Row(1, "a"), Row(2, "b"), Row(3, "c"), Row(4, "d")])
        XCTAssertEqual(diff(old, StoreBuilder.store([Row(2, "b"), Row(3, "c"), Row(4, "d"), Row(1, "a")], order: [0, 1, 2, 3])).changes,
                       ChangeSet([.move(from: 0, to: 3)]))
        XCTAssertEqual(diff(old, StoreBuilder.store([Row(1, "a"), Row(2, "b"), Row(3, "c"), Row(4, "d")], order: [3, 0, 1, 2])).changes,
                       ChangeSet([.move(from: 3, to: 0)]))
    }

    func testReversalUsesMinimalMoves() {
        let rows = (1...10).map { Row(UInt64($0), "n\($0)") }
        let r = diff(StoreBuilder.store(rows), StoreBuilder.store(rows, order: (0..<10).reversed().map { UInt32($0) }))
        XCTAssertEqual(r.changes.changes.count, 9)
    }

    func testChangeOrderIsRemoveMoveInsertReload() {
        let old = StoreBuilder.store([Row(1, "a"), Row(2, "b"), Row(3, "c"), Row(4, "d")])
        let new = StoreBuilder.store([Row(3, "c"), Row(1, "a", mtime: 1), Row(5, "e"), Row(4, "d")])
        let r = diff(old, new)
        XCTAssertEqual(r.changes, ChangeSet([.remove(IndexSet(integer: 1)), .move(from: 0, to: 1),
                                             .insert(IndexSet(integer: 2)), .reload(IndexSet(integer: 1))]))
    }

    // MARK: visibility, identity modes, duplicates

    func testHiddenRowBecomingVisibleIsInsert() {
        let rows = [Row(1, "a"), Row(2, ".b", hidden: true), Row(3, "c")]
        let old = StoreBuilder.store(rows)
        let new = StoreBuilder.store(rows, order: [0, 1, 2])
        XCTAssertEqual(diff(old, new).changes, ChangeSet([.insert(IndexSet(integer: 1))]))
        XCTAssertEqual(diff(new, old).changes, ChangeSet([.remove(IndexSet(integer: 1))]))
    }

    func testNameIdentityRenameIsRemovePlusInsert() {
        let mode = IdentityMode.name(caseSensitive: false)
        let old = StoreBuilder.store([Row(0, "a"), Row(0, "b")], mode: mode)
        let new = StoreBuilder.store([Row(0, "b"), Row(0, "d")], mode: mode)
        let r = diff(old, new)
        XCTAssertEqual(r.changes, ChangeSet([.remove(IndexSet(integer: 0)), .insert(IndexSet(integer: 1))]))
        XCTAssertEqual(r.replacements, [])
    }

    func testNameIdentityCaseOnlyRenameOnCaseInsensitiveVolumeIsReload() {
        let mode = IdentityMode.name(caseSensitive: false)
        let r = diff(StoreBuilder.store([Row(0, "readme")], mode: mode), StoreBuilder.store([Row(0, "README")], mode: mode))
        XCTAssertEqual(r.changes, ChangeSet([.reload(IndexSet(integer: 0))]))
    }

    func testDuplicateIdentitiesNeverTrap() {
        let old = StoreBuilder.store([Row(7, "x"), Row(7, "y"), Row(1, "a"), Row(7, "z")])
        let fewer = StoreBuilder.store([Row(1, "a"), Row(7, "x")])
        let more = StoreBuilder.store([Row(7, "x"), Row(7, "y"), Row(7, "y2"), Row(7, "z"), Row(1, "a"), Row(7, "w")])
        _ = diff(old, fewer)
        _ = diff(fewer, old)
        _ = diff(old, more)
        _ = diff(more, old)
        // Zero rowIDs fall back to exact-name identity.
        _ = diff(StoreBuilder.store([Row(0, "q"), Row(0, "q"), Row(0, "r")]), StoreBuilder.store([Row(0, "q"), Row(0, "s")]))
    }

    func testLargeChangeSetRequiresReloadData() {
        let old = StoreBuilder.store([])
        let new = StoreBuilder.store((1...2_000).map { Row(UInt64($0), "f\($0)") })
        let r = diff(old, new)
        XCTAssertTrue(r.changes.requiresReloadData)
        XCTAssertEqual(r.changes.touchedRowCount, 2_000)
    }

    // MARK: property test

    func testRandomizedDiffAppliesToEqualOrder() {
        var rng = SplitMix64(seed: 0x6D61_6378)
        for iteration in 0..<400 {
            let mode: IdentityMode = iteration % 4 == 3 ? .name(caseSensitive: iteration % 8 == 3) : .objectID
            let (old, new) = Self.randomPair(&rng, mode: mode, maxCount: iteration < 300 ? 24 : 200)
            let result = StoreDiff.diff(old: old, new: new)
            DiffChecker.check(old: old, new: new, result: result)
            if testRun?.failureCount ?? 0 > 0 {
                XCTFail("first failing iteration \(iteration), mode \(mode)")
                return
            }
        }
    }

    /// Old rows, then a mutated copy: removals, additions, mtime/size edits, renames, atomic saves, duplicate
    /// identities, hidden toggles, and a random or name-sorted display order on each side.
    static func randomPair(_ rng: inout SplitMix64, mode: IdentityMode, maxCount: Int) -> (EntryStore, EntryStore) {
        let count = Int.random(in: 0...maxCount, using: &rng)
        var nextID: UInt64 = 1
        func freshID(_ rng: inout SplitMix64) -> UInt64 {
            if Int.random(in: 0..<20, using: &rng) == 0 { return 0 }               // degraded: name identity
            if Int.random(in: 0..<15, using: &rng) == 0, nextID > 1 { return UInt64.random(in: 1..<nextID, using: &rng) }  // duplicate
            defer { nextID += 1 }
            return nextID
        }
        func randomName(_ rng: inout SplitMix64) -> String {
            let pool = ["a", "b", "c", "A", "d", "e\u{301}", "\u{e9}", "f", "g", "h"]
            return pool[Int.random(in: 0..<pool.count, using: &rng)] + String(Int.random(in: 0..<(maxCount / 2 + 3), using: &rng))
        }
        var oldRows: [Row] = []
        for _ in 0..<count {
            oldRows.append(Row(freshID(&rng), randomName(&rng), mtime: Int64.random(in: 0..<3, using: &rng),
                               hidden: Int.random(in: 0..<8, using: &rng) == 0))
        }
        var newRows: [Row] = []
        for var row in oldRows {
            switch Int.random(in: 0..<12, using: &rng) {
            case 0: continue                                                       // removed
            case 1: row.mtime += 1                                                 // modified
            case 2: row.size += 1
            case 3: row.name = randomName(&rng)                                    // renamed
            case 4: row.id = freshID(&rng)                                         // atomic save
            case 5: row.hidden.toggle()
            default: break
            }
            newRows.append(row)
            if Int.random(in: 0..<10, using: &rng) == 0 {                           // added
                newRows.append(Row(freshID(&rng), randomName(&rng)))
            }
        }
        newRows.shuffle(using: &rng)
        return (store(oldRows, &rng, mode: mode), store(newRows, &rng, mode: mode))
    }

    private static func store(_ rows: [Row], _ rng: inout SplitMix64, mode: IdentityMode) -> EntryStore {
        var visible = rows.indices.filter { !rows[$0].hidden || Int.random(in: 0..<3, using: &rng) == 0 }
        if Bool.random(using: &rng) {
            visible.sort { (rows[$0].name, $0) < (rows[$1].name, $1) }
        } else {
            visible.shuffle(using: &rng)
        }
        return StoreBuilder.store(rows, order: visible.map { UInt32($0) }, mode: mode)
    }

    // MARK: performance smoke (debug build; the gate is macx-bench)

    func testDiffOf100kWithOnePercentChangesIsFast() {
        let n = 100_000
        let rows = (0..<n).map { Row(UInt64($0 + 1), String(format: "file-%06d.txt", $0), mtime: 1) }
        let old = StoreBuilder.store(rows)
        var newRows = rows
        for i in stride(from: 0, to: n, by: 100) { newRows[i].mtime = 2 }                        // 1% modified
        for i in stride(from: 50, to: n, by: 200) { newRows[i].hidden = true }                    // 0.5% removed
        newRows += (0..<500).map { Row(UInt64(n + 10 + $0), "added-\($0).txt") }                  // 0.5% added
        let new = StoreBuilder.store(newRows)
        let start = ContinuousClock.now
        let r = StoreDiff.diff(old: old, new: new)
        let elapsed = ContinuousClock.now - start
        XCTAssertEqual(r.changes.touchedRowCount, 1_000 + 500 + 500)
        XCTAssertLessThan(elapsed, .milliseconds(1_600), "4x the 400 ms full re-read budget")
    }
}

/// Deterministic PRNG for reproducible property tests.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
