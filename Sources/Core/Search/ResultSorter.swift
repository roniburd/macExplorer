import Foundation
import MacxFS

/// Display order of search results. Same rules as Sorter (folders first, field, name tie-break, descending
/// reverses within the folder/file groups) plus `.path`: parent path, then name, with no folder grouping.
/// Extended Phase 2 fields are not offered for results and sort like `.name`. Remaining ties break on the parent
/// path and then the storage index, so the order is total (a full sort and incremental merges agree).
enum ResultSorter {
    /// `parentKeys[i]` is `parentKey(r.parents[i])` for every parent (the model extends it incrementally: parents
    /// are never removed from a SearchResultStore).
    static func parentKey(_ path: String) -> [UInt8] { SortKeys.nameKey(path, isFolder: false) }

    static func parentKeys(_ r: SearchResultStore, extending keys: SortKeyColumn) -> SortKeyColumn {
        var keys = keys
        let parents = r.parents
        guard keys.count < parents.count else { return keys }
        for p in parents[keys.count...] { parentKey(p).withUnsafeBytes { keys.append($0) } }
        return keys
    }

    static func less(_ r: SearchResultStore, _ sort: MacxFS.SortDescriptor, kindRanks: [UInt16],
                     parentKeys: SortKeyColumn) -> (UInt32, UInt32) -> Bool {
        let store = r.store
        let keys = r.nameKeys
        let asc = sort.ascending
        func cmp(_ ka: UnsafeRawBufferPointer, _ kb: UnsafeRawBufferPointer) -> Int {
            let n = min(ka.count, kb.count)
            let c = n == 0 ? 0 : Int(memcmp(ka.baseAddress!, kb.baseAddress!, n))
            return c != 0 ? c : ka.count - kb.count
        }
        func cmpKeys(_ col: SortKeyColumn, _ a: Int, _ b: Int, dropFirst: Bool = false) -> Int {
            col.withKey(a) { ka in col.withKey(b) { kb in
                guard dropFirst, ka.count > 0, kb.count > 0 else { return cmp(ka, kb) }
                return cmp(UnsafeRawBufferPointer(rebasing: ka.dropFirst()), UnsafeRawBufferPointer(rebasing: kb.dropFirst()))
            } }
        }
        func parent(_ a: UInt32, _ b: UInt32) -> Int {
            let pa = Int(r.parentIndex(a)), pb = Int(r.parentIndex(b))
            return pa == pb ? 0 : cmpKeys(parentKeys, pa, pb)
        }
        func index(_ a: UInt32, _ b: UInt32) -> Int { a == b ? 0 : (a < b ? -1 : 1) }
        if sort.field == .path {
            return { a, b in
                var c = parent(a, b)
                if c == 0 { c = cmpKeys(keys, Int(a), Int(b), dropFirst: true) }   // name without the folder byte
                if c == 0 { c = index(a, b) }
                return asc ? c < 0 : c > 0
            }
        }
        func ext(_ i: UInt32) -> [UInt8] {
            guard store.entry(i).kind != .directory else { return [] }
            return store.withNameBytes(i) { bytes in
                guard let dot = bytes.lastIndex(of: UInt8(ascii: ".")), dot > 0, dot < bytes.count - 1 else { return [] }
                return bytes[(dot + 1)...].map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }
            }
        }
        return { a, b in
            let ea = store.entry(a), eb = store.entry(b)
            let fa = ea.isFolderForSorting, fb = eb.isFolderForSorting
            if fa != fb { return fa }
            var c: Int
            switch sort.field {
            case .dateModified: c = ea.mtime == eb.mtime ? 0 : (ea.mtime < eb.mtime ? -1 : 1)
            case .dateCreated: c = ea.ctime == eb.ctime ? 0 : (ea.ctime < eb.ctime ? -1 : 1)
            case .size: c = fa ? 0 : (ea.size == eb.size ? 0 : (ea.size < eb.size ? -1 : 1))
            case .kind:
                let ra = kindRanks.indices.contains(Int(ea.typeIndex)) ? kindRanks[Int(ea.typeIndex)] : .max
                let rb = kindRanks.indices.contains(Int(eb.typeIndex)) ? kindRanks[Int(eb.typeIndex)] : .max
                c = ra == rb ? 0 : (ra < rb ? -1 : 1)
            case .fileExtension:
                let xa = ext(a), xb = ext(b)
                c = xa == xb ? 0 : (xa.lexicographicallyPrecedes(xb) ? -1 : 1)
            default: c = 0
            }
            if c == 0 { c = cmpKeys(keys, Int(a), Int(b)) }
            if c == 0 { c = parent(a, b) }
            if c == 0 { c = index(a, b) }
            return asc ? c < 0 : c > 0
        }
    }

    static func permutation(_ r: SearchResultStore, sort: MacxFS.SortDescriptor, kindRanks: [UInt16], parentKeys: SortKeyColumn) -> [UInt32] {
        let less = less(r, sort, kindRanks: kindRanks, parentKeys: parentKeys)
        return (0..<UInt32(r.count)).sorted(by: less)
    }

    /// Full sort off the main actor, on a snapshot (the model applies no op to its store while this runs).
    @concurrent
    static func permutationOffMain(_ r: SearchResultStore, sort: MacxFS.SortDescriptor, kindRanks: [UInt16],
                                   parentKeys: SortKeyColumn) async -> [UInt32] {
        permutation(r, sort: sort, kindRanks: kindRanks, parentKeys: parentKeys)
    }

    /// `sorted` is a valid order; `fresh` are new storage indices not in it. O(n + k log k).
    static func merge(_ sorted: [UInt32], _ fresh: [UInt32], results r: SearchResultStore, sort: MacxFS.SortDescriptor,
                      kindRanks: [UInt16], parentKeys: SortKeyColumn) -> [UInt32] {
        guard !fresh.isEmpty else { return sorted }
        let less = less(r, sort, kindRanks: kindRanks, parentKeys: parentKeys)
        let run = fresh.sorted(by: less)
        guard !sorted.isEmpty else { return run }
        var out: [UInt32] = []
        out.reserveCapacity(sorted.count + run.count)
        var i = 0, j = 0
        while i < sorted.count && j < run.count {
            if less(run[j], sorted[i]) { out.append(run[j]); j += 1 } else { out.append(sorted[i]); i += 1 }
        }
        out.append(contentsOf: sorted[i...])
        out.append(contentsOf: run[j...])
        return out
    }
}
