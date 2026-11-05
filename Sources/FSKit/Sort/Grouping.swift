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
    /// `.none` returns (sorted, []). O(n) plus one key computation per distinct type/bucket and per non-ASCII name.
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
            for (i, index) in sorted.enumerated() {
                assigned[i] = store.withNameBytes(index) { bytes -> Int32 in
                    let start = bytes.firstIndex { $0 != UInt8(ascii: ".") } ?? bytes.endIndex
                    // ASCII fast path: an ASCII first byte not followed by a combining (non-ASCII) scalar.
                    if start < bytes.endIndex, bytes[start] < 0x80, start + 1 == bytes.endIndex || bytes[start + 1] < 0x80 {
                        let b = Int(bytes[start])
                        if ascii[b] < 0 { ascii[b] = id(.letter(asciiLetterKey(UInt8(b)))) }
                        return ascii[b]
                    }
                    let end = min(bytes.endIndex, start + 32)
                    return id(.letter(letterKey(String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<end]), as: UTF8.self))))
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

    private static func asciiLetterKey(_ byte: UInt8) -> LetterKey {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return .digits
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): return .letter(String(UnicodeScalar(byte)))
        case UInt8(ascii: "a")...UInt8(ascii: "z"): return .letter(String(UnicodeScalar(byte - 32)))
        default: return .other
        }
    }
}
