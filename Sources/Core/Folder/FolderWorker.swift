import Foundation
import MacxFS

/// Off-main half of a FolderModel (§4.3 ownership 2–3): sort keys, the sorted merge while loading, re-sorts,
/// incremental patches and diffs. It never makes a file-system call and never mutates the model's store; it returns
/// permutations and new stores that main applies.
///
/// Sort keys (name, extension, cached search) are kept per storage index of the model's store. They are tagged:
/// every result that changes storage returns a new `KeysTag`, and every call passes the tag of the store main
/// holds. A mismatch (main dropped a result) rebuilds the keys from the store passed in, so keys never drift.
actor FolderWorker {
    typealias KeysTag = UInt64

    /// The Group by a result is computed for (P2-09): every display order the worker returns is partitioned with
    /// it, and carries its `revision`, so main can tell a result computed for an older grouping.
    struct GroupSpec: Sendable, Equatable {
        var groupBy: GroupBy
        var buckets: DateBuckets
        var revision: Int

        static let none = GroupSpec(groupBy: .none, buckets: DateBuckets(now: Date(timeIntervalSince1970: 0),
                                                                          calendar: Calendar(identifier: .gregorian)),
                                    revision: 0)
    }

    /// A display order and its groups (empty when not grouped).
    struct Ordered: Sendable {
        var order: [UInt32]
        var runs: [GroupRun]
        var revision: Int
    }

    struct Keys: Sendable {
        var name = SortKeyColumn()
        var ext = SortKeyColumn()
        var search: SortKeyColumn?         // searchFold per storage index; built on the first filtered sort

        mutating func append(_ batch: Batch) {
            name.append(contentsOf: SortKeys.nameKeys(batch))
            ext.append(contentsOf: SortKeys.extensionKeys(batch))
            search = nil
        }

        static func build(_ store: EntryStore) -> Keys {
            Keys(name: SortKeys.nameKeys(store, range: 0..<store.count), ext: SortKeys.extensionKeys(store, range: 0..<store.count))
        }
    }

    /// A read in progress: its own copy of the store (same storage indices as main's when loading), keys,
    /// the sorted permutation of everything merged so far, and sorted runs not merged yet.
    private struct Building {
        var generation: Generation
        var store: EntryStore
        var keys = Keys()
        var order: [UInt32] = []
        var runs: [[UInt32]] = []
        var dirty = false
        var query: ViewQuery
        /// Grouping revision of the last loading order handed out (a grouping change re-presents the frame).
        var presentedRevision: Int?
    }

    struct PatchResult: Sendable {
        var store: EntryStore
        var diff: DiffResult
        var tag: KeysTag
        /// Groups of `store.order` (P2-09) and the grouping revision they were computed for.
        var runs: [GroupRun] = []
        var groupRevision = 0
    }

    private let types: TypeRegistry
    private var keys = Keys()
    private var tag: KeysTag = 0
    private var nextTag: KeysTag = 0
    private var building: Building?

    init(types: TypeRegistry) { self.types = types }

    // MARK: Loading and re-reads

    /// Starts collecting the batches of read `generation` (replacing any read in progress).
    /// Starts a listing. Fresh loads call this from a detached task, so a superseded load's call can arrive after
    /// a newer one: begins older than the newest seen are ignored.
    func begin(_ generation: Generation, identityMode: IdentityMode, query: ViewQuery) {
        if let newest = newestBegun, generation < newest { return }
        newestBegun = generation
        building = Building(generation: generation, store: EntryStore(identityMode: identityMode), query: query)
    }
    private var newestBegun: Generation?

    /// Drops the read in progress (navigation, close, retry).
    func cancel() { building = nil }

    /// Appends a batch of the current read and sorts it within itself. False for a stale generation.
    @discardableResult
    func ingest(_ batch: Batch) -> Bool {
        guard building?.generation == batch.generation, batch.count > 0 else { return building?.generation == batch.generation }
        let lower = building!.store.count
        building!.store.append(batch)
        building!.keys.append(batch)
        let b = building!
        let run = Sorter.sortedRun(b.store, range: lower..<b.store.count, nameKeys: b.keys.name, searchKeys: nil,
                                   query: b.query, kindRanks: types.kindRanks().ranks, extensionKeys: b.keys.ext)
        building!.runs.append(run)
        building!.dirty = true
        return true
    }

    /// Re-sorts the read in progress for a new query.
    func setLoadingQuery(_ query: ViewQuery) {
        guard var b = building, b.query != query else { return }
        building = nil
        b.query = query
        b.runs = []
        b.order = permutation(b.store, b.keys, query)
        b.dirty = true
        building = b
    }

    /// The sorted permutation of every row merged so far, or nil if nothing changed since the last call
    /// (or `generation` is not the read in progress). At most one call per display frame.
    func takeLoadingOrder(_ generation: Generation, group: GroupSpec = .none) -> Ordered? {
        guard building?.generation == generation,
              building!.dirty || building!.presentedRevision.map({ $0 != group.revision }) == true else { return nil }
        mergeRuns()
        building!.dirty = false
        building!.presentedRevision = group.revision
        let b = building!
        let (order, runs) = partition(b.store, sorted: b.order, by: group.groupBy, buckets: group.buckets)
        return Ordered(order: order, runs: runs, revision: group.revision)
    }

    /// Initial load or retry finished: main's store holds the same batches in the same order. Returns the final
    /// permutation for `query` and adopts the read's keys; the read's store copy is dropped.
    func finishLoad(_ generation: Generation, query: ViewQuery, group: GroupSpec = .none)
        -> (order: [UInt32], tag: KeysTag, runs: [GroupRun], revision: Int)? {
        guard building?.generation == generation else { return nil }
        if building!.query != query { setLoadingQuery(query) } else { mergeRuns() }
        let b = building!
        building = nil
        keys = b.keys
        let (order, runs) = partition(b.store, sorted: b.order, by: group.groupBy, buckets: group.buckets)
        return (order, newTag(), runs, group.revision)
    }

    /// A re-read (refresh, full rescan) finished: the new listing replaces `old`. Returns the sorted new store
    /// and its diff against `old`.
    func finishReread(_ generation: Generation, old: EntryStore, query: ViewQuery, group: GroupSpec = .none) -> PatchResult? {
        guard building?.generation == generation else { return nil }
        if building!.query != query { setLoadingQuery(query) } else { mergeRuns() }
        var b = building!
        building = nil
        let (order, runs) = partition(b.store, sorted: b.order, by: group.groupBy, buckets: group.buckets)
        b.store.setOrder(order)
        keys = b.keys
        let diff = StoreDiff.diff(old: old, new: b.store)
        return PatchResult(store: b.store, diff: diff, tag: newTag(), runs: runs, groupRevision: group.revision)
    }

    // MARK: Complete folders

    /// Display permutation of `store` for `query` (re-sort, filter, show hidden).
    func resort(_ store: EntryStore, tag storeTag: KeysTag, query: ViewQuery, group: GroupSpec = .none) -> Ordered {
        sync(store, storeTag)
        if !query.filter.isEmpty && keys.search == nil { keys.search = SortKeys.searchKeys(store) }
        let (order, runs) = partition(store, sorted: permutation(store, keys, query), by: group.groupBy, buckets: group.buckets)
        return Ordered(order: order, runs: runs, revision: group.revision)
    }

    /// Group by (P2-09): stable partition of a sorted permutation of `snapshot` (CPU only, no file-system calls).
    func partition(_ snapshot: EntryStore, sorted: [UInt32], by groupBy: GroupBy, buckets: DateBuckets)
        -> (order: [UInt32], runs: [GroupRun]) {
        guard groupBy != .none else { return (sorted, []) }
        let signpost = PerfSignposts.signposter.beginInterval(PerfSignposts.group)
        defer { PerfSignposts.signposter.endInterval(PerfSignposts.group, signpost) }
        return Grouping.partition(sorted, store: snapshot, by: groupBy, dateBuckets: buckets, types: types)
    }

    /// Applies a stat of some names (watcher incremental path, LocalChange): present names are upserted (and any
    /// other identity holding that name removed, so an atomic save becomes a replacement), missing names lose their
    /// rows, names that failed keep their rows with the errno. Returns the re-sorted store and its diff.
    func patch(_ old: EntryStore, tag storeTag: KeysTag, result: ItemReadResult, query: ViewQuery,
               caseSensitive: Bool, group: GroupSpec = .none) -> PatchResult {
        sync(old, storeTag)
        var store = old
        var k = keys
        k.search = nil
        var present: [String: UInt32] = [:]          // identityName → upserted storage index
        var touched = Set<UInt32>()                  // storage indices (before removal) whose content may change
        for i in 0..<result.batch.count {
            let name = result.batch.name(at: i), entry = result.batch.entries[i]
            let before = store.count
            let index = store.upsert(entry, name: name)
            let nameKey = SortKeys.nameKey(name, isFolder: entry.isFolderForSorting)
            let extKey = SortKeys.extensionKey(name, kind: entry.kind)
            if Int(index) == before {
                nameKey.withUnsafeBytes { k.name.append($0) }
                extKey.withUnsafeBytes { k.ext.append($0) }
            } else {
                k.name.replace(Int(index), with: nameKey)
                k.ext.replace(Int(index), with: extKey)
            }
            present[NameNormalizer.identityName(name, caseSensitive: caseSensitive)] = index
            touched.insert(index)
        }
        for error in result.batch.errors where Int(error.index) < result.batch.count {
            if let index = present[NameNormalizer.identityName(result.batch.name(at: Int(error.index)), caseSensitive: caseSensitive)] {
                store.setError(error.code, at: index)
                touched.insert(index)
            }
        }

        let missing = Set(result.missing.map { NameNormalizer.identityName($0, caseSensitive: caseSensitive) })
        let failed = Dictionary(result.errors.map { (NameNormalizer.identityName($0.key, caseSensitive: caseSensitive), $0.value) },
                                uniquingKeysWith: { a, _ in a })
        var removed = Set<UInt32>()
        if !missing.isEmpty || !present.isEmpty || !failed.isEmpty {
            // Cheap pre-filter: an ASCII name's identity name has its byte length, so ASCII rows whose length no
            // target has cannot match (skips building and normalizing a String per row in 100k folders).
            var lengths = Set<Int>()
            for name in missing { lengths.insert(name.utf8.count) }
            for name in present.keys { lengths.insert(name.utf8.count) }
            for name in failed.keys { lengths.insert(name.utf8.count) }
            for i in 0..<UInt32(store.count) {
                let skip = store.withNameBytes(i) { bytes in !lengths.contains(bytes.count) && bytes.allSatisfy { $0 < 0x80 } }
                if skip { continue }
                let name = NameNormalizer.identityName(store.name(i), caseSensitive: caseSensitive)
                if missing.contains(name) {
                    removed.insert(i)
                } else if let keep = present[name], keep != i {
                    removed.insert(i)                // another identity held the name: replaced
                } else if let code = failed[name] {
                    store.setError(code, at: i)
                    touched.insert(i)
                }
            }
        }
        // EntryStore.remove compacts in place: old storage index i moves down by the removed indices below it.
        var storageMap = [Int32](repeating: -1, count: old.count)
        var below: Int32 = 0
        for i in 0..<store.count {
            if removed.contains(UInt32(i)) { below += 1; continue }
            if i < old.count { storageMap[i] = Int32(i) - below }
        }
        var touchedAfter = Set<UInt32>()
        if !removed.isEmpty {
            let sortedRemoved = removed.sorted()
            for index in touched where !removed.contains(index) {
                var lo = 0, hi = sortedRemoved.count
                while lo < hi { let mid = (lo + hi) / 2; if sortedRemoved[mid] < index { lo = mid + 1 } else { hi = mid } }
                touchedAfter.insert(index - UInt32(lo))
            }
        } else {
            touchedAfter = touched
        }
        store.remove(removed)
        k.name.remove(removed)
        k.ext.remove(removed)
        let (order, runs) = partition(store, sorted: permutation(store, k, query), by: group.groupBy, buckets: group.buckets)
        store.setOrder(order)
        keys = k
        let diff = StoreDiff.diff(old: old, new: store, storageMap: storageMap, touched: touchedAfter)
        return PatchResult(store: store, diff: diff, tag: newTag(), runs: runs, groupRevision: group.revision)
    }

    // MARK: Private

    private func sync(_ store: EntryStore, _ storeTag: KeysTag) {
        guard storeTag != tag || keys.name.count != store.count else { return }
        keys = Keys.build(store)
        tag = storeTag
    }

    private func newTag() -> KeysTag {
        nextTag += 1
        tag = nextTag
        return tag
    }

    private func permutation(_ store: EntryStore, _ keys: Keys, _ query: ViewQuery) -> [UInt32] {
        Sorter.permutation(store, nameKeys: keys.name, searchKeys: query.filter.isEmpty ? nil : keys.search, query: query,
                           kindRanks: types.kindRanks().ranks, extensionKeys: keys.ext)
    }

    /// Merges the pending sorted runs into the building order (pairwise, so a frame's work is O(n log runs)).
    private func mergeRuns() {
        guard var b = building, !b.runs.isEmpty else { return }
        building = nil
        let ranks = types.kindRanks().ranks
        var runs = b.runs
        while runs.count > 1 {
            var next: [[UInt32]] = []
            var i = 0
            while i < runs.count {
                if i + 1 < runs.count {
                    next.append(Sorter.merge(runs[i], runs[i + 1], store: b.store, nameKeys: b.keys.name, query: b.query,
                                             kindRanks: ranks, extensionKeys: b.keys.ext))
                } else {
                    next.append(runs[i])
                }
                i += 2
            }
            runs = next
        }
        b.order = Sorter.merge(b.order, runs[0], store: b.store, nameKeys: b.keys.name, query: b.query, kindRanks: ranks,
                               extensionKeys: b.keys.ext)
        b.runs = []
        building = b
    }
}
