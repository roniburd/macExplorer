import Foundation
import MacxFS

/// An atomic save seen by the diff: `old` disappeared and `new` appeared with the same name. Selection, scroll
/// anchor and inline-rename state move from `old` to `new`.
public struct Replacement: Sendable, Equatable {
    public var old: RowID
    public var new: RowID
    public init(old: RowID, new: RowID) { self.old = old; self.new = new }
}

public struct DiffResult: Sendable, Equatable {
    public var changes: ChangeSet
    public var replacements: [Replacement]   // atomic-save replacements (move selection/anchor/rename state)
    public init(changes: ChangeSet, replacements: [Replacement]) {
        self.changes = changes
        self.replacements = replacements
    }
}

public enum StoreDiff {
    /// Visible-order diff by identity: match identity; within the batch, disappeared identity + new identity
    /// with the same name = replacement → reload; same identity, changed mtime/size/name → reload (+ move if
    /// position changed); rest → remove/insert. Duplicate identities never trap.
    ///
    /// Duplicate identities match by occurrence (the k-th old row with an identity pairs with the k-th new
    /// one). Replacement names compare NFC, case-sensitively. Any entry field, name byte or errno change counts
    /// as a change. Output order: one `remove` (old indices), the minimum number of `move`s (longest increasing
    /// subsequence kept in place), one `insert` (final indices), one `reload` (final indices). O(n log n).
    public static func diff(old: EntryStore, new: EntryStore) -> DiffResult {
        var match = matchIdentities(old: old, new: new)
        return finish(old: old, new: new, match: &match, touched: nil)
    }

    /// Patch fast path (FolderWorker.patch): `new` was derived from `old` in place, so rows correspond by storage
    /// index. `storageMap[i]` is the storage index in `new` of old storage index `i` (-1 = removed); only new
    /// storage indices in `touched` (and replacements) can have changed content. Same result as `diff(old:new:)`
    /// when every kept row keeps its identity, without hashing every identity of a 100k folder.
    public static func diff(old: EntryStore, new: EntryStore, storageMap: [Int32], touched: Set<UInt32>) -> DiffResult {
        precondition(storageMap.count == old.count, "StoreDiff: storageMap must cover every old storage index")
        var newRow = [Int32](repeating: -1, count: new.count)
        for p in 0..<new.visibleCount { newRow[Int(new.storageIndex(forRow: p))] = Int32(p) }
        var match = Match(oldToNew: [Int](repeating: -1, count: old.visibleCount),
                          newToOld: [Int](repeating: -1, count: new.visibleCount),
                          replaced: [Bool](repeating: false, count: new.visibleCount))
        for r in 0..<old.visibleCount {
            let target = storageMap[Int(old.storageIndex(forRow: r))]
            guard target >= 0 else { continue }
            let p = Int(newRow[Int(target)])
            guard p >= 0 else { continue }
            match.oldToNew[r] = p
            match.newToOld[p] = r
        }
        return finish(old: old, new: new, match: &match, touched: touched)
    }

    /// Replacements, removals, insertions, reloads (all matched rows, or only `touched` new storage indices) and moves.
    private static func finish(old: EntryStore, new: EntryStore, match: inout Match, touched: Set<UInt32>?) -> DiffResult {
        let replacements = matchReplacements(old: old, new: new, match: &match)

        var removed = IndexSet(), inserted = IndexSet(), reloaded = IndexSet()
        for r in 0..<old.visibleCount where match.oldToNew[r] < 0 { removed.insert(r) }
        for p in 0..<new.visibleCount {
            let r = match.newToOld[p]
            if r < 0 { inserted.insert(p); continue }
            let ni = new.storageIndex(forRow: p)
            if match.replaced[p] { reloaded.insert(p); continue }
            if let touched, !touched.contains(ni) { continue }
            if !sameContent(old, old.storageIndex(forRow: r), new, ni) { reloaded.insert(p) }
        }

        var changes: [Change] = []
        if !removed.isEmpty { changes.append(.remove(removed)) }
        changes += moves(match)
        if !inserted.isEmpty { changes.append(.insert(inserted)) }
        if !reloaded.isEmpty { changes.append(.reload(reloaded)) }
        return DiffResult(changes: ChangeSet(changes), replacements: replacements)
    }

    // MARK: Matching

    private struct Match {
        var oldToNew: [Int]     // display row in new, -1 = removed
        var newToOld: [Int]     // display row in old, -1 = inserted
        var replaced: [Bool]    // per new row: matched by the replacement rule
    }

    private static func matchIdentities(old: EntryStore, new: EntryStore) -> Match {
        var match = Match(oldToNew: [Int](repeating: -1, count: old.visibleCount),
                          newToOld: [Int](repeating: -1, count: new.visibleCount),
                          replaced: [Bool](repeating: false, count: new.visibleCount))
        var first: [RowID: Int] = [:]
        first.reserveCapacity(old.visibleCount)
        var duplicates: [RowID: [Int]] = [:]   // later occurrences, reversed so popLast yields the next one
        for r in 0..<old.visibleCount {
            let id = old.identity(old.storageIndex(forRow: r))
            if first[id] == nil { first[id] = r } else { duplicates[id, default: []].insert(r, at: 0) }
        }
        for p in 0..<new.visibleCount {
            let id = new.identity(new.storageIndex(forRow: p))
            let r: Int? = if let r = first.removeValue(forKey: id) { r } else { duplicates[id]?.popLast() }
            if let r {
                match.oldToNew[r] = p
                match.newToOld[p] = r
            }
        }
        return match
    }

    /// Pairs still-unmatched old and new rows that share an NFC name, in display order.
    private static func matchReplacements(old: EntryStore, new: EntryStore, match: inout Match) -> [Replacement] {
        var byName: [String: [Int]] = [:]   // reversed occurrence lists
        for r in 0..<old.visibleCount where match.oldToNew[r] < 0 {
            byName[NameNormalizer.nfc(old.name(old.storageIndex(forRow: r))), default: []].insert(r, at: 0)
        }
        guard !byName.isEmpty else { return [] }
        var replacements: [Replacement] = []
        for p in 0..<new.visibleCount where match.newToOld[p] < 0 {
            let ni = new.storageIndex(forRow: p)
            guard let r = byName[NameNormalizer.nfc(new.name(ni))]?.popLast() else { continue }
            match.oldToNew[r] = p
            match.newToOld[p] = r
            match.replaced[p] = true
            replacements.append(Replacement(old: old.identity(old.storageIndex(forRow: r)), new: new.identity(ni)))
        }
        return replacements
    }

    private static func sameContent(_ a: EntryStore, _ ai: UInt32, _ b: EntryStore, _ bi: UInt32) -> Bool {
        let x = a.entry(ai), y = b.entry(bi)
        guard x.rowID == y.rowID, x.fileID == y.fileID, x.size == y.size, x.allocSize == y.allocSize,
              x.mtime == y.mtime, x.ctime == y.ctime, x.nameLen == y.nameLen, x.kind == y.kind,
              x.flags == y.flags, x.typeIndex == y.typeIndex, a.errno(ai) == b.errno(bi) else { return false }
        // A localized-name patch changes only the shown name: it must still reload the row.
        if a.hasLocalizedStems || b.hasLocalizedStems, a.localizedStem(ai) != b.localizedStem(bi) { return false }
        return a.withNameBytes(ai) { an in b.withNameBytes(bi) { bn in an.elementsEqual(bn) } }
    }

    // MARK: Moves

    /// Moves that turn the matched rows' old order (after the removal) into their new order (before the
    /// insertion). Rows on a longest increasing subsequence of targets stay; every other row moves, in ascending
    /// target order, to just after the row that precedes it in the new order. Positions come from a Fenwick tree
    /// over the sorted set of all (base, sub) ordering keys.
    private static func moves(_ match: Match) -> [Change] {
        var rank = [Int](repeating: -1, count: match.newToOld.count)
        var k = 0
        for p in match.newToOld.indices where match.newToOld[p] >= 0 { rank[p] = k; k += 1 }
        var targets: [Int] = []          // per matched item in old order: its position in the new order
        targets.reserveCapacity(k)
        for p in match.oldToNew where p >= 0 { targets.append(rank[p]) }
        if zip(targets, targets.dropFirst()).allSatisfy({ $0 < $1 }) { return [] }

        let stays = longestIncreasingSubsequence(targets)
        var itemAtTarget = [Int](repeating: 0, count: k)
        for (i, t) in targets.enumerated() { itemAtTarget[t] = i }

        // Ordering keys: item i starts at (i, 0); a moved item gets (base, sub + 1) of its predecessor in the
        // new order. Encoded so integer order is (base, sub) order; base -1 is "before everything".
        func encode(_ base: Int, _ sub: Int) -> Int { ((base + 1) << 32) | sub }
        var base = Array(0..<k), sub = [Int](repeating: 0, count: k)
        var moved: [(item: Int, newKey: Int)] = []
        for t in 0..<k where !stays[itemAtTarget[t]] {
            let x = itemAtTarget[t]
            if t == 0 { base[x] = -1; sub[x] = 0 } else {
                let p = itemAtTarget[t - 1]
                base[x] = base[p]
                sub[x] = sub[p] + 1
            }
            moved.append((x, encode(base[x], sub[x])))
        }
        let allKeys = ((0..<k).map { encode($0, 0) } + moved.map(\.newKey)).sorted()
        func rankOf(_ key: Int) -> Int {
            var lo = 0, hi = allKeys.count
            while lo < hi { let mid = (lo + hi) / 2; if allKeys[mid] < key { lo = mid + 1 } else { hi = mid } }
            return lo
        }

        var tree = Fenwick(count: allKeys.count)
        for i in 0..<k { tree.add(rankOf(encode(i, 0)), 1) }
        var changes: [Change] = []
        changes.reserveCapacity(moved.count)
        for (x, newKey) in moved {
            let oldRank = rankOf(encode(x, 0))
            let from = tree.prefixSum(oldRank)
            tree.add(oldRank, -1)
            let newRank = rankOf(newKey)
            let to = tree.prefixSum(newRank)
            tree.add(newRank, 1)
            changes.append(.move(from: from, to: to))
        }
        return changes
    }

    /// Membership flags of one longest strictly increasing subsequence of `values`. O(n log n).
    private static func longestIncreasingSubsequence(_ values: [Int]) -> [Bool] {
        var tails: [Int] = []                                     // indices into values
        var previous = [Int](repeating: -1, count: values.count)
        for (i, v) in values.enumerated() {
            var lo = 0, hi = tails.count
            while lo < hi { let mid = (lo + hi) / 2; if values[tails[mid]] < v { lo = mid + 1 } else { hi = mid } }
            if lo > 0 { previous[i] = tails[lo - 1] }
            if lo == tails.count { tails.append(i) } else { tails[lo] = i }
        }
        var member = [Bool](repeating: false, count: values.count)
        var i = tails.last ?? -1
        while i >= 0 { member[i] = true; i = previous[i] }
        return member
    }
}

/// Binary indexed tree of counts over ranks 0..<count.
private struct Fenwick {
    private var tree: [Int]
    init(count: Int) { tree = [Int](repeating: 0, count: count + 1) }

    mutating func add(_ rank: Int, _ delta: Int) {
        var i = rank + 1
        while i < tree.count { tree[i] += delta; i += i & -i }
    }

    /// Sum over ranks 0..<rank.
    func prefixSum(_ rank: Int) -> Int {
        var i = rank, sum = 0
        while i > 0 { sum += tree[i]; i -= i & -i }
        return sum
    }
}
