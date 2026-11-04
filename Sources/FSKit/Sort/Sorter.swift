import Darwin
import Dispatch
import Foundation
import Synchronization

public enum Sorter {
    /// Visible storage indices of `store` in display order: hidden rows excluded unless query.showHidden,
    /// rows not matching query.filter (byte substring of searchKeys) excluded, folders first, then the sort
    /// field (name: memcmp of nameKeys; dates/size: integer key, name tie-break; kind: TypeRegistry rank
    /// then name; extension: folded extension then name). Size sort orders folders by name (their size is
    /// "--"). Descending reverses within each folders/files group; folders stay first.
    /// `extensionKeys` (SortKeys.extensionKeys, one per storage index) is used by fileExtension sorts; nil
    /// computes it for the whole store on each call.
    public static func permutation(_ store: EntryStore, nameKeys: SortKeyColumn, searchKeys: SortKeyColumn?,
                                   query: ViewQuery, kindRanks: [UInt16], extensionKeys: SortKeyColumn? = nil) -> [UInt32] {
        sortedRun(store, range: 0..<store.count, nameKeys: nameKeys, searchKeys: searchKeys, query: query, kindRanks: kindRanks,
                  extensionKeys: extensionKeys)
    }

    /// Like `permutation`, restricted to storage indices in `range` (the loading path sorts each new batch
    /// with this, then `merge`s it, passing incrementally built extensionKeys). Addition to the §3.5 contract.
    public static func sortedRun(_ store: EntryStore, range: Range<Int>, nameKeys: SortKeyColumn, searchKeys: SortKeyColumn?,
                                 query: ViewQuery, kindRanks: [UInt16], extensionKeys: SortKeyColumn? = nil) -> [UInt32] {
        precondition(nameKeys.count >= range.upperBound, "Sorter: nameKeys must cover every storage index")
        let filter = query.filter.isEmpty ? nil : SortKeys.searchFold(query.filter)
        let ordering = Ordering(store: store, nameKeys: nameKeys, query: query, kindRanks: kindRanks, extensionKeys: extensionKeys)
        @Sendable func sortedItems(_ part: Range<Int>) -> [Item] {
            var items: [Item] = []
            items.reserveCapacity(part.count)
            for i in part {
                let index = UInt32(i)
                let entry = store.entry(index)
                if !query.showHidden && entry.flags.isHidden { continue }
                if let filter, !matches(index, store: store, searchKeys: searchKeys, filter: filter) { continue }
                items.append(ordering.item(index))
            }
            ordering.sort(&items)
            return items
        }
        let chunks = parallelChunks(range.count)
        guard chunks > 1 else { return sortedItems(range).map(\.index) }
        // Large folders (§4.4 re-sort 100k < 30 ms): sort contiguous chunks concurrently, then merge the runs.
        // One locked write per chunk, no unsafe sharing.
        let size = (range.count + chunks - 1) / chunks
        let parts = Mutex([[Item]](repeating: [], count: chunks))
        DispatchQueue.concurrentPerform(iterations: chunks) { c in
            let lower = range.lowerBound + c * size
            let part = sortedItems(lower..<min(range.upperBound, lower + size))
            parts.withLock { $0[c] = part }
        }
        var runs = parts.withLock { $0 }
        while runs.count > 1 {
            var next: [[Item]] = []
            next.reserveCapacity((runs.count + 1) / 2)
            var r = 0
            while r + 1 < runs.count { next.append(ordering.merge(runs[r], runs[r + 1])); r += 2 }
            if r < runs.count { next.append(runs[r]) }
            runs = next
        }
        return runs[0].map(\.index)
    }

    /// Concurrent chunk count for sorting `count` rows: 1 below 32k rows, else up to 8 (one per active core).
    static func parallelChunks(_ count: Int) -> Int {
        guard count >= 32_768 else { return 1 }
        return max(1, min(8, ProcessInfo.processInfo.activeProcessorCount, count / 8_192))
    }

    /// Loading path: merge an already-sorted run of new indices into a sorted permutation.
    public static func merge(_ sorted: [UInt32], _ run: [UInt32], store: EntryStore, nameKeys: SortKeyColumn,
                             query: ViewQuery, kindRanks: [UInt16], extensionKeys: SortKeyColumn? = nil) -> [UInt32] {
        if run.isEmpty { return sorted }
        if sorted.isEmpty { return run }
        let ordering = Ordering(store: store, nameKeys: nameKeys, query: query, kindRanks: kindRanks, extensionKeys: extensionKeys)
        return ordering.merge(sorted.map(ordering.item), run.map(ordering.item)).map(\.index)
    }

    static func matches(_ index: UInt32, store: EntryStore, searchKeys: SortKeyColumn?, filter: [UInt8]) -> Bool {
        if filter.isEmpty { return true }
        if let searchKeys, Int(index) < searchKeys.count {
            return searchKeys.withKey(Int(index)) { contains($0, filter) }
        }
        let folded = SortKeys.searchFold(store.name(index))
        return folded.withUnsafeBytes { contains($0, filter) }
    }

    private static func contains(_ haystack: UnsafeRawBufferPointer, _ needle: [UInt8]) -> Bool {
        guard haystack.count >= needle.count else { return false }
        return needle.withUnsafeBytes { n in memmem(haystack.baseAddress, haystack.count, n.baseAddress, n.count) != nil }
    }
}

/// Sort item: group (folders 0 / files 1) | primary integer key | first 16 name-key bytes | storage index.
/// 16 bytes cover the digit-run encoding of typical numbered names ("IMG_0042.jpg"), so most ties resolve
/// with integer compares instead of a memcmp into the key arena.
struct Item: Sendable {
    var group: UInt8
    var primary: UInt64
    var prefix: UInt64
    var prefix2: UInt64
    var index: UInt32
}

struct Ordering: Sendable {
    let store: EntryStore
    let nameKeys: SortKeyColumn
    let field: SortField
    let ascending: Bool
    let kindRanks: [UInt16]
    /// fileExtension sort: folded extension key per storage index (empty column for other fields).
    private let extensionKeys: SortKeyColumn

    init(store: EntryStore, nameKeys: SortKeyColumn, query: ViewQuery, kindRanks: [UInt16], extensionKeys: SortKeyColumn?) {
        self.store = store
        self.nameKeys = nameKeys
        self.field = query.sort.field
        self.ascending = query.sort.ascending
        self.kindRanks = kindRanks
        guard query.sort.field == .fileExtension else { self.extensionKeys = SortKeyColumn(); return }
        // Without a caller-maintained column every call folds the whole store: fine for one-off sorts,
        // too slow per loading batch (pass SortKeys.extensionKeys built incrementally there).
        let keys = extensionKeys ?? SortKeys.extensionKeys(store, range: 0..<store.count)
        precondition(keys.count >= store.count, "Sorter: extensionKeys must cover every storage index")
        self.extensionKeys = keys
    }

    /// First 8 bytes of a key, big-endian, zero-padded (folded names contain no NUL bytes).
    private static func prefix(_ key: UnsafeRawBufferPointer) -> UInt64 { prefix(key, from: 0) }

    /// 8 key bytes starting at `from`, big-endian, zero-padded.
    private static func prefix(_ key: UnsafeRawBufferPointer, from: Int) -> UInt64 {
        var p: UInt64 = 0
        for k in from..<(from + 8) { p = (p << 8) | UInt64(k < key.count ? key[k] : 0) }
        return p
    }

    func item(_ index: UInt32) -> Item {
        let e = store.entry(index)
        let folder = e.isFolderForSorting
        let primary: UInt64
        switch field {
        case .name: primary = 0
        case .fileExtension: primary = extensionKeys.withKey(Int(index), Ordering.prefix)
        case .dateModified: primary = UInt64(bitPattern: e.mtime) ^ (1 << 63)
        case .dateCreated: primary = UInt64(bitPattern: e.ctime) ^ (1 << 63)
        case .size: primary = folder ? 0 : UInt64(bitPattern: e.size) ^ (1 << 63)
        case .kind: primary = Int(e.typeIndex) < kindRanks.count ? UInt64(kindRanks[Int(e.typeIndex)]) : UInt64(UInt16.max)
        }
        let (prefix, prefix2) = nameKeys.withKey(Int(index)) { (Ordering.prefix($0, from: 0), Ordering.prefix($0, from: 8)) }
        return Item(group: folder ? 0 : 1, primary: primary, prefix: prefix, prefix2: prefix2, index: index)
    }

    /// Calls `body` with a strict-weak-order `less` (total: the storage index breaks remaining ties).
    /// The key arenas are opened once, so each comparison is integer compares plus at most two memcmps
    /// (the second only for extensions longer than the 8-byte primary); names equal in their first 16 bytes
    /// fall back to memcmp of the whole key.
    func withLess<R>(_ body: ((Item, Item) -> Bool) -> R) -> R {
        nameKeys.withStorage { bytes, starts, lengths in
            extensionKeys.withStorage { extBytes, extStarts, extLengths in
                let ascending = self.ascending, byExtension = field == .fileExtension
                func ordered(_ a: Item, _ b: Item) -> Bool {
                    if a.primary != b.primary { return a.primary < b.primary }
                    if byExtension, max(extLengths[Int(a.index)], extLengths[Int(b.index)]) > 8 {   // equal 8-byte prefixes
                        let c = Ordering.compare(a.index, b.index, extBytes, extStarts, extLengths)
                        if c != 0 { return c < 0 }
                    }
                    if a.prefix != b.prefix { return a.prefix < b.prefix }
                    if a.prefix2 != b.prefix2 { return a.prefix2 < b.prefix2 }
                    let c = Ordering.compare(a.index, b.index, bytes, starts, lengths)
                    if c != 0 { return c < 0 }
                    return a.index < b.index
                }
                return body { a, b in
                    if a.group != b.group { return a.group < b.group }
                    return ascending ? ordered(a, b) : ordered(b, a)
                }
            }
        }
    }

    /// memcmp of two keys in an arena, shorter-is-smaller on a common prefix.
    @inline(__always)
    private static func compare(_ a: UInt32, _ b: UInt32, _ bytes: UnsafeRawBufferPointer,
                                _ starts: UnsafeBufferPointer<UInt32>, _ lengths: UnsafeBufferPointer<UInt32>) -> Int32 {
        let la = Int(lengths[Int(a)]), lb = Int(lengths[Int(b)])
        if la > 0 && lb > 0, let base = bytes.baseAddress {
            let c = memcmp(base + Int(starts[Int(a)]), base + Int(starts[Int(b)]), min(la, lb))
            if c != 0 { return c }
        }
        return la == lb ? 0 : (la < lb ? -1 : 1)
    }

    /// Stable merge of two sorted runs (ties keep `a` first).
    func merge(_ a: [Item], _ b: [Item]) -> [Item] {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        var out: [Item] = []
        out.reserveCapacity(a.count + b.count)
        var i = 0, j = 0
        withLess { less in
            while i < a.count && j < b.count {
                if less(b[j], a[i]) { out.append(b[j]); j += 1 } else { out.append(a[i]); i += 1 }
            }
        }
        out.append(contentsOf: a[i...])
        out.append(contentsOf: b[j...])
        return out
    }

    func sort(_ items: inout [Item]) {
        guard items.count > 1 else { return }
        nameKeys.withStorage { bytes, starts, lengths in
            extensionKeys.withStorage { extBytes, extStarts, extLengths in
                // Literal closures (one per direction) so the comparison inlines into the sort; `withLess`'s
                // closure-of-closure costs two indirect calls per comparison on 100k-row re-sorts (§4.4).
                let byExtension = field == .fileExtension
                @inline(__always) func ordered(_ a: Item, _ b: Item) -> Bool {
                    if a.primary != b.primary { return a.primary < b.primary }
                    if byExtension, max(extLengths[Int(a.index)], extLengths[Int(b.index)]) > 8 {
                        let c = Ordering.compare(a.index, b.index, extBytes, extStarts, extLengths)
                        if c != 0 { return c < 0 }
                    }
                    if a.prefix != b.prefix { return a.prefix < b.prefix }
                    if a.prefix2 != b.prefix2 { return a.prefix2 < b.prefix2 }
                    let c = Ordering.compare(a.index, b.index, bytes, starts, lengths)
                    if c != 0 { return c < 0 }
                    return a.index < b.index
                }
                if ascending {
                    items.sort { a, b in a.group != b.group ? a.group < b.group : ordered(a, b) }
                } else {
                    items.sort { a, b in a.group != b.group ? a.group < b.group : ordered(b, a) }
                }
            }
        }
    }
}
