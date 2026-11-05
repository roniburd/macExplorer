import Foundation

/// Date Modified groups (spec §11), in display order. The first matching lower bound wins, so "Yesterday" beats
/// "Last week" on the first day of a week.
public enum DateBucket: Int, Sendable, Hashable, CaseIterable {
    case future, today, yesterday, earlierThisWeek, lastWeek, earlierThisMonth, lastMonth, earlierThisYear, longAgo
}

/// Size groups (Explorer buckets, binary units), in display order.
public enum SizeBucket: Int, Sendable, Hashable, CaseIterable {
    case folders, empty, tiny, small, medium, large, huge, gigantic
}

/// Name groups: "0–9", one per (folded, upper-cased) first letter of any script, then "#" for everything else.
public enum LetterKey: Hashable, Sendable { case digits, letter(String), other }

/// One group of a grouped folder. UI formats it (L10n); `kind` carries TypeRegistry.localizedDescription.
public enum GroupKey: Hashable, Sendable {
    case kind(String, isFolder: Bool)
    case date(DateBucket)
    case size(SizeBucket)
    case letter(LetterKey)
}

/// A contiguous range of model (display-order) rows that belong to one group.
public struct GroupRun: Sendable, Equatable {
    public var key: GroupKey
    public var rows: Range<Int>
    public init(key: GroupKey, rows: Range<Int>) { self.key = key; self.rows = rows }
}

/// The Date Modified bucket boundaries for one "now" in one calendar (time zone, first weekday).
public struct DateBuckets: Sendable, Equatable {
    /// Lower bounds in ns since 1970 for: future (tomorrow), today, yesterday, this week, last week, this month,
    /// last month, this year.
    let starts: [Int64]
    /// Start of tomorrow: the buckets change then, so a date-grouped folder regroups.
    public let nextBoundary: Date
    private static let order: [DateBucket] = [.future, .today, .yesterday, .earlierThisWeek, .lastWeek,
                                              .earlierThisMonth, .lastMonth, .earlierThisYear]

    public init(now: Date, calendar: Calendar) {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today.addingTimeInterval(-86_400)
        let week = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
        let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: week) ?? week
        let month = calendar.dateInterval(of: .month, for: now)?.start ?? today
        let lastMonth = calendar.date(byAdding: .month, value: -1, to: month) ?? month
        let year = calendar.dateInterval(of: .year, for: now)?.start ?? month
        func ns(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970.rounded(.down)) * 1_000_000_000 }
        starts = [tomorrow, today, yesterday, week, lastWeek, month, lastMonth, year].map(ns)
        nextBoundary = tomorrow
    }

    public func bucket(forNanoseconds t: Int64) -> DateBucket {
        DateBucket(rawValue: Self.bucketIndex(t, starts))!
    }

    /// Index into DateBucket of `t` (a plain loop: the 100k partition calls it once per row).
    static func bucketIndex(_ t: Int64, _ starts: UnsafeBufferPointer<Int64>) -> Int {
        var i = 0
        while i < starts.count {
            if t >= starts[i] { return i }
            i += 1
        }
        return starts.count
    }

    static func bucketIndex(_ t: Int64, _ starts: [Int64]) -> Int {
        starts.withUnsafeBufferPointer { bucketIndex(t, $0) }
    }
}

/// Group by (spec §11): a stable partition of an already sorted permutation. CPU only, no file-system calls;
/// FolderWorker runs it off main.
public enum Grouping {
    public static func sizeBucket(bytes: Int64, isFolder: Bool) -> SizeBucket {
        if isFolder { return .folders }
        switch bytes {
        case ..<1: return .empty
        case ...16_384: return .tiny
        case ...1_048_576: return .small
        case ...134_217_728: return .medium
        case ...1_073_741_824: return .large
        case ...4_294_967_296: return .huge
        default: return .gigantic
        }
    }

    private static let posix = Locale(identifier: "en_US_POSIX")

    /// First grapheme after leading dots, folded case/diacritic/width-insensitively and upper-cased.
    public static func letterKey(_ name: String) -> LetterKey {
        guard let first = name.drop(while: { $0 == "." }).first else { return .other }
        if first.unicodeScalars.count == 1, first.unicodeScalars.first!.properties.numericType == .decimal { return .digits }
        guard first.isLetter else { return .other }
        let folded = String(first).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: posix)
        guard let letter = folded.uppercased().first else { return .other }
        return .letter(String(letter))
    }

    /// Strict weak order of groups: Kind puts "Folder" first then descriptions; dates and sizes in bucket order;
    /// names "0–9", letters, then "#". Keys of different modes never occur together.
    public static func groupOrder(_ a: GroupKey, _ b: GroupKey) -> Bool {
        switch (a, b) {
        case let (.kind(da, fa), .kind(db, fb)):
            if fa != fb { return fa }
            let c = da.localizedStandardCompare(db)
            return c == .orderedSame ? da < db : c == .orderedAscending
        case let (.date(x), .date(y)): return x.rawValue < y.rawValue
        case let (.size(x), .size(y)): return x.rawValue < y.rawValue
        case let (.letter(x), .letter(y)): return letterBefore(x, y)
        default: return false
        }
    }

    static func letterBefore(_ a: LetterKey, _ b: LetterKey) -> Bool {
        switch (a, b) {
        case (.digits, .digits), (.other, .other): return false
        case (.digits, _): return true
        case (_, .digits): return false
        case (.other, _): return false
        case (_, .other): return true
        case let (.letter(x), .letter(y)):
            let c = x.localizedStandardCompare(y)
            return c == .orderedSame ? x < y : c == .orderedAscending
        }
    }

    /// Stable partition of an already sorted permutation into contiguous groups (in-group order preserved).
    /// `.none` returns (sorted, []). O(n) plus one key computation per distinct type/bucket and per distinct first-grapheme prefix.
    public static func partition(_ sorted: [UInt32], store: EntryStore, by groupBy: GroupBy,
                                 dateBuckets: DateBuckets, types: TypeRegistry) -> (order: [UInt32], runs: [GroupRun]) {
        guard groupBy != .none, !sorted.isEmpty else { return (sorted, []) }
        var keys: [GroupKey] = []
        var ids: [GroupKey: Int32] = [:]
        func id(_ key: GroupKey) -> Int32 {
            if let existing = ids[key] { return existing }
            let new = Int32(keys.count)
            keys.append(key)
            ids[key] = new
            return new
        }
        var assigned = [Int32](repeating: 0, count: sorted.count)
        switch groupBy {
        case .none:
            return (sorted, [])
        case .kind:
            var byType: [UInt16: Int32] = [:]
            var folderID: Int32?
            var descriptions: [String: Int32] = [:]
            for (i, index) in sorted.enumerated() {
                let e = store.entry(index)
                if e.isFolderForSorting {
                    if folderID == nil { folderID = id(.kind(types.localizedDescription(TypeRegistry.folderIndex), isFolder: true)) }
                    assigned[i] = folderID!
                } else if let known = byType[e.typeIndex] {
                    assigned[i] = known
                } else {
                    let description = types.localizedDescription(e.typeIndex)
                    let new = descriptions[description] ?? id(.kind(description, isFolder: false))
                    descriptions[description] = new
                    byType[e.typeIndex] = new
                    assigned[i] = new
                }
            }
        case .dateModified:
            var byBucket = [Int32](repeating: -1, count: DateBucket.allCases.count)
            dateBuckets.starts.withUnsafeBufferPointer { starts in
                for (i, index) in sorted.enumerated() {
                    let b = DateBuckets.bucketIndex(store.entry(index).mtime, starts)
                    if byBucket[b] < 0 { byBucket[b] = id(.date(DateBucket(rawValue: b)!)) }
                    assigned[i] = byBucket[b]
                }
            }
        case .size:
            var byBucket = [Int32](repeating: -1, count: SizeBucket.allCases.count)
            for (i, index) in sorted.enumerated() {
                let e = store.entry(index)
                let bucket = sizeBucket(bytes: e.size, isFolder: e.isFolderForSorting)
                if byBucket[bucket.rawValue] < 0 { byBucket[bucket.rawValue] = id(.size(bucket)) }
                assigned[i] = byBucket[bucket.rawValue]
            }
        case .nameFirstLetter:
            var ascii = [Int32](repeating: -1, count: 128)
            var prefixes = PrefixTable()
            for (i, index) in sorted.enumerated() {
                assigned[i] = store.withNameBytes(index) { bytes -> Int32 in
                    let start = bytes.firstIndex { $0 != UInt8(ascii: ".") } ?? bytes.endIndex
                    if start == bytes.endIndex { return id(.letter(.other)) }
                    // ASCII fast path: an ASCII first byte not followed by a combining (non-ASCII) scalar.
                    if bytes[start] < 0x80, start + 1 == bytes.endIndex || bytes[start + 1] < 0x80 {
                        let b = Int(bytes[start])
                        if ascii[b] < 0 { ascii[b] = id(.letter(asciiLetterKey(UInt8(b)))) }
                        return ascii[b]
                    }
                    return cachedLetterID(bytes, from: start, cache: &prefixes, id: id)
                }
            }
        }
        // Counting sort by group, groups in display order: stable within each group.
        var counts = [Int](repeating: 0, count: keys.count)
        for g in assigned { counts[Int(g)] += 1 }
        let groupOrderIDs = keys.indices.sorted { groupOrder(keys[$0], keys[$1]) }
        var offsets = [Int](repeating: 0, count: keys.count)
        var runs: [GroupRun] = []
        runs.reserveCapacity(keys.count)
        var next = 0
        for g in groupOrderIDs {
            offsets[g] = next
            runs.append(GroupRun(key: keys[g], rows: next ..< next + counts[g]))
            next += counts[g]
        }
        var order = [UInt32](repeating: 0, count: sorted.count)
        for (i, index) in sorted.enumerated() {
            let g = Int(assigned[i])
            order[offsets[g]] = index
            offsets[g] += 1
        }
        return (order, runs)
    }

    /// The UTF-8 bytes of a name's first grapheme plus the scalar after it (or the name's end), ≤ 16 bytes packed.
    /// A grapheme boundary depends only on the scalars before it and the one scalar after it (UAX #29), so such a
    /// prefix decides the first grapheme of every name that starts with it.
    struct GraphemePrefix: Equatable {
        var lo: UInt64 = 0, hi: UInt64 = 0
        static let capacity = 15

        init() {}

        /// `count` and `ended` go in the top byte of `hi` (15 bytes of payload fit beside it).
        init(_ bytes: UnsafeBufferPointer<UInt8>, _ range: Range<Int>, ended: Bool) {
            var j = range.lowerBound, k = 0
            while j < range.upperBound {
                if k < 8 { lo |= UInt64(bytes[j]) << (8 * k) } else { hi |= UInt64(bytes[j]) << (8 * (k - 8)) }
                j += 1; k += 1
            }
            hi |= UInt64(range.count) << 56 | (ended ? 1 << 63 : 0)
        }
    }

    /// GraphemePrefix → entry, open addressing over plain arrays (a generic Dictionary is several times slower in
    /// debug builds, and the 100k partition does one or two lookups per row). Entries: ≥ 0 is a group id (the
    /// prefix's first k scalars are the first grapheme); `longer` means they are not (a combining mark, ZWJ or
    /// regional indicator follows), so look up the prefix one scalar longer. `hi == 0` marks an empty slot (a real
    /// key's `hi` carries its count).
    struct PrefixTable {
        static let longer: Int32 = -2
        private var lo = [UInt64](repeating: 0, count: 64)
        private var hi = [UInt64](repeating: 0, count: 64)
        private var values = [Int32](repeating: 0, count: 64)
        private var used = 0
        /// The last key looked up (rows sorted by name share it): one comparison instead of a probe.
        private var last = GraphemePrefix(), lastValue: Int32 = 0

        private func slot(_ key: GraphemePrefix) -> Int {
            let mask = lo.count - 1
            var i = Int(truncatingIfNeeded: ((key.lo ^ (key.hi << 32 | key.hi >> 32)) &* 0x9E37_79B9_7F4A_7C15) >> 40) & mask
            while hi[i] != 0, lo[i] != key.lo || hi[i] != key.hi { i = (i + 1) & mask }
            return i
        }

        mutating func value(_ key: GraphemePrefix) -> Int32? {
            if key == last { return lastValue }
            let i = slot(key)
            guard hi[i] != 0 else { return nil }
            last = key
            lastValue = values[i]
            return values[i]
        }

        mutating func set(_ key: GraphemePrefix, _ value: Int32) {
            if (used + 1) * 2 > lo.count { grow() }
            let i = slot(key)
            if hi[i] == 0 { used += 1 }
            lo[i] = key.lo; hi[i] = key.hi; values[i] = value
        }

        private mutating func grow() {
            let old = (lo, hi, values)
            lo = [UInt64](repeating: 0, count: old.0.count * 2)
            hi = [UInt64](repeating: 0, count: old.0.count * 2)
            values = [Int32](repeating: 0, count: old.0.count * 2)
            for j in old.0.indices where old.1[j] != 0 {
                var key = GraphemePrefix()
                key.lo = old.0[j]; key.hi = old.1[j]
                let i = slot(key)
                lo[i] = key.lo; hi[i] = key.hi; values[i] = old.2[j]
            }
        }
    }

    /// The name-group id of the name whose letters start at `start`, computed once per distinct grapheme prefix:
    /// most rows cost one or two small-key hash lookups. Invalid UTF-8 and graphemes over 15 bytes are uncached.
    private static func cachedLetterID(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int,
                                       cache: inout PrefixTable, id: (GroupKey) -> Int32) -> Int32 {
        func uncached() -> Int32 {
            let end = min(bytes.endIndex, start + 64)
            return id(.letter(letterKey(String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<end]), as: UTF8.self))))
        }
        guard let first = scalarLength(bytes, at: start) else { return uncached() }
        var graphemeEnd = start + first
        while true {
            let ended = graphemeEnd == bytes.endIndex
            var keyEnd = graphemeEnd
            if !ended {
                guard let next = scalarLength(bytes, at: graphemeEnd) else { return uncached() }
                keyEnd += next
            }
            guard keyEnd - start <= GraphemePrefix.capacity else { return uncached() }
            let key = GraphemePrefix(bytes, start..<keyEnd, ended: ended)
            if let value = cache.value(key) {
                if value != PrefixTable.longer { return value }
                graphemeEnd = keyEnd
                continue
            }
            let prefix = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<keyEnd]), as: UTF8.self)
            if ended || prefix.first!.utf8.count <= graphemeEnd - start {
                let g = id(.letter(letterKey(prefix)))
                cache.set(key, g)
                return g
            }
            cache.set(key, PrefixTable.longer)
            graphemeEnd = keyEnd
        }
    }

    /// Byte length of the well-formed UTF-8 scalar at `i`, nil for ill-formed input (overlong, surrogate, truncated).
    /// Plain comparisons, no range patterns: those are generic calls in debug builds.
    static func scalarLength(_ b: UnsafeBufferPointer<UInt8>, at i: Int) -> Int? {
        let lead = b[i]
        if lead < 0x80 { return 1 }
        let n: Int
        var lo: UInt8 = 0x80, hi: UInt8 = 0xBF
        if lead < 0xC2 { return nil }
        else if lead < 0xE0 { n = 2 }
        else if lead < 0xF0 {
            n = 3
            if lead == 0xE0 { lo = 0xA0 } else if lead == 0xED { hi = 0x9F }
        } else if lead < 0xF5 {
            n = 4
            if lead == 0xF0 { lo = 0x90 } else if lead == 0xF4 { hi = 0x8F }
        } else { return nil }
        guard i + n <= b.endIndex, b[i + 1] >= lo, b[i + 1] <= hi else { return nil }
        var j = i + 2
        while j < i + n {
            if b[j] < 0x80 || b[j] > 0xBF { return nil }
            j += 1
        }
        return n
    }

    private static func asciiLetterKey(_ byte: UInt8) -> LetterKey {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return .digits
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): return .letter(String(UnicodeScalar(byte)))
        case UInt8(ascii: "a")...UInt8(ascii: "z"): return .letter(String(UnicodeScalar(byte - 32)))
        default: return .other
        }
    }
}
