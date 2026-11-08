import XCTest
@testable import MacxFS

final class GroupingTests: XCTestCase {
    let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!; c.firstWeekday = 1; c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()
    func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
    func ns(_ s: String) -> Int64 { Int64(date(s).timeIntervalSince1970) * 1_000_000_000 }

    func testDateBucketsMidMonth() {   // 2026-11-18 is a Wednesday; week starts Sunday 11-15
        let b = DateBuckets(now: date("2026-11-18T15:00:00Z"), calendar: utc)
        let cases: [(String, DateBucket)] = [
            ("2026-11-19T01:00:00Z", .future), ("2026-11-18T00:00:00Z", .today), ("2026-11-17T23:59:59Z", .yesterday),
            ("2026-11-15T00:00:00Z", .earlierThisWeek), ("2026-11-14T12:00:00Z", .lastWeek), ("2026-11-08T00:00:00Z", .lastWeek),
            ("2026-11-07T23:59:59Z", .earlierThisMonth), ("2026-11-01T00:00:00Z", .earlierThisMonth),
            ("2026-10-31T10:00:00Z", .lastMonth), ("2026-10-01T00:00:00Z", .lastMonth),
            ("2026-09-30T10:00:00Z", .earlierThisYear), ("2026-01-01T00:00:00Z", .earlierThisYear),
            ("2025-12-31T23:59:59Z", .longAgo),
        ]
        for (s, expected) in cases { XCTAssertEqual(b.bucket(forNanoseconds: ns(s)), expected, s) }
        XCTAssertEqual(b.bucket(forNanoseconds: ns("2026-11-18T00:00:00Z") - 1), .yesterday, "1 ns before midnight")
        XCTAssertEqual(b.nextBoundary, date("2026-11-19T00:00:00Z"))
    }

    func testDateBucketsOnFirstDayOfWeekAndMonth() {   // 2026-11-01 is a Sunday
        let b = DateBuckets(now: date("2026-11-01T10:00:00Z"), calendar: utc)
        XCTAssertEqual(b.bucket(forNanoseconds: ns("2026-10-31T12:00:00Z")), .yesterday, "yesterday wins over last week")
        XCTAssertEqual(b.bucket(forNanoseconds: ns("2026-10-26T12:00:00Z")), .lastWeek)
        XCTAssertEqual(b.bucket(forNanoseconds: ns("2026-10-24T12:00:00Z")), .lastMonth)
    }

    func testSizeBuckets() {
        XCTAssertEqual(Grouping.sizeBucket(bytes: 123, isFolder: true), .folders)
        XCTAssertEqual(Grouping.sizeBucket(bytes: 0, isFolder: false), .empty)
        XCTAssertEqual(Grouping.sizeBucket(bytes: 1, isFolder: false), .tiny)
        XCTAssertEqual(Grouping.sizeBucket(bytes: 16_384, isFolder: false), .tiny)
        XCTAssertEqual(Grouping.sizeBucket(bytes: 16_385, isFolder: false), .small)
        XCTAssertEqual(Grouping.sizeBucket(bytes: 1_048_576, isFolder: false), .small)
        XCTAssertEqual(Grouping.sizeBucket(bytes: 134_217_728, isFolder: false), .medium)
        XCTAssertEqual(Grouping.sizeBucket(bytes: 134_217_729, isFolder: false), .large)
        XCTAssertEqual(Grouping.sizeBucket(bytes: 1_073_741_825, isFolder: false), .huge)
        XCTAssertEqual(Grouping.sizeBucket(bytes: 4_294_967_297, isFolder: false), .gigantic)
    }

    func testLetterKeys() {
        let cases: [(String, LetterKey)] = [
            ("apple", .letter("A")), ("Äpfel", .letter("A")), ("A\u{0308}pfel", .letter("A")), ("éclair", .letter("E")),
            (".env", .letter("E")), ("Ωmega", .letter("Ω")), ("日本", .letter("日")), ("Ａbc", .letter("A")),
            ("2024 report", .digits), ("１x", .digits), ("_x", .other), ("😀.png", .other), ("", .other), ("...", .other),
        ]
        for (name, key) in cases { XCTAssertEqual(Grouping.letterKey(name), key, name) }
    }

    func testGroupOrder() {
        let keys: [GroupKey] = [.letter(.other), .letter(.letter("b")), .letter(.digits), .letter(.letter("A"))]
        XCTAssertEqual(keys.sorted(by: Grouping.groupOrder), [.letter(.digits), .letter(.letter("A")), .letter(.letter("b")), .letter(.other)])
        let kinds: [GroupKey] = [.kind("PNG image", isFolder: false), .kind("Folder", isFolder: true), .kind("Plain Text Document", isFolder: false)]
        XCTAssertEqual(kinds.sorted(by: Grouping.groupOrder).first, .kind("Folder", isFolder: true))
        XCTAssertEqual(kinds.sorted(by: Grouping.groupOrder)[1], .kind("Plain Text Document", isFolder: false))
    }

    func makeStore(_ items: [(name: String, kind: Kind, size: Int64, mtime: Int64)]) -> EntryStore {
        let types = TypeRegistry.shared
        var store = EntryStore(identityMode: .name(caseSensitive: false))
        var batch = Batch(generation: .initial)
        for (i, it) in items.enumerated() {
            let parts = it.name.split(separator: ".", omittingEmptySubsequences: false)
            let ext = parts.count > 1 ? parts.last! : Substring("")
            let e = Entry(rowID: UInt64(i + 1), fileID: UInt64(i + 1), size: it.size, allocSize: it.size, mtime: it.mtime, ctime: it.mtime,
                          nameOffset: 0, nameLen: 0, kind: it.kind, flags: [],
                          typeIndex: it.kind == .directory ? TypeRegistry.folderIndex : types.index(forExtension: ext, isDirectory: false))
            Array(it.name.utf8).withUnsafeBufferPointer { batch.append(e, nameBytes: $0) }
        }
        store.append(batch)
        store.setOrder(Array(0..<UInt32(items.count)))
        return store
    }

    func testPartitionIsStableAndContiguous() {
        let store = makeStore([("sub", .directory, 3, 0), ("a.txt", .file, 10, 0), ("c.png", .file, 20, 0), ("b.txt", .file, 0, 0)])
        let b = DateBuckets(now: Date(timeIntervalSince1970: 0), calendar: utc)
        let (order, runs) = Grouping.partition(store.order, store: store, by: .kind, dateBuckets: b, types: .shared)
        XCTAssertEqual(order.map { store.name($0) }.first, "sub")
        let txt = runs.first { if case .kind(_, false) = $0.key, order[$0.rows.lowerBound] == 1 { return true }; return false }!
        XCTAssertEqual(txt.rows.map { store.name(order[$0]) }, ["a.txt", "b.txt"], "in-group order is the input sort order")
        XCTAssertEqual(runs.map(\.rows.count).reduce(0, +), 4)
        XCTAssertEqual(zip(runs, runs.dropFirst()).allSatisfy { $0.rows.upperBound == $1.rows.lowerBound }, true)
        let (sizeOrder, sizeRuns) = Grouping.partition(store.order, store: store, by: .size, dateBuckets: b, types: .shared)
        XCTAssertEqual(sizeRuns.map(\.key), [.size(.folders), .size(.empty), .size(.tiny)])
        XCTAssertEqual(sizeOrder.map { store.name($0) }, ["sub", "b.txt", "a.txt", "c.png"])
        XCTAssertEqual(Grouping.partition(store.order, store: store, by: .none, dateBuckets: b, types: .shared).runs, [])
        let (letterOrder, letterRuns) = Grouping.partition(store.order, store: store, by: .nameFirstLetter, dateBuckets: b, types: .shared)
        XCTAssertEqual(letterRuns.map(\.key), [.letter(.letter("A")), .letter(.letter("B")), .letter(.letter("C")), .letter(.letter("S"))])
        XCTAssertEqual(letterOrder.map { store.name($0) }, ["a.txt", "b.txt", "c.png", "sub"])
    }

    /// Name groups follow the name shown: a Finder localized stem (merge of the display-names work) decides the letter.
    func testNameGroupsUseLocalizedStem() {
        var store = makeStore([("Applications", .directory, 0, 0), ("Zeta", .directory, 0, 0)])
        store.setLocalizedStem("Programme", at: 0)
        let b = DateBuckets(now: Date(timeIntervalSince1970: 0), calendar: utc)
        let (order, runs) = Grouping.partition(store.order, store: store, by: .nameFirstLetter, dateBuckets: b, types: .shared)
        XCTAssertEqual(runs.map(\.key), [.letter(.letter("P")), .letter(.letter("Z"))])
        XCTAssertEqual(order.map { store.name($0) }, ["Applications", "Zeta"])
    }

    func testPartitionOfSubsetKeepsOnlyGivenRows() {
        let store = makeStore([("x.txt", .file, 1, 0), ("y.txt", .file, 1, 0), ("z.png", .file, 1, 0)])
        let b = DateBuckets(now: Date(timeIntervalSince1970: 0), calendar: utc)
        let (order, runs) = Grouping.partition([2, 0], store: store, by: .kind, dateBuckets: b, types: .shared)
        XCTAssertEqual(Set(order), [0, 2])
        XCTAssertEqual(runs.count, 2)
    }

    /// 100k rows by every Group by: the partition is a permutation whose runs tile the rows in group order, one run
    /// per key, stable within each run, and every row is in the run of its own key. No timing here: a debug build
    /// under `swift test --parallel` on a shared runner measures the runner. The budget is `macx-bench
    /// --check-budgets` (`resort.grouped.*` and `resort.grouped.nameFirstLetter.nonASCII`, 30 ms, release build).
    func testPartition100kIsAStablePermutationIntoKeyedRuns() {
        let items = (0..<100_000).map { (name: "file \($0 % 977) \($0).\(["txt", "png", "swift", "md"][$0 % 4])", kind: Kind.file, size: Int64($0 * 37), mtime: Int64($0) * 86_400_000_000_000) }
        let store = makeStore(items)
        let b = DateBuckets(now: Date(timeIntervalSince1970: 100_000 * 86_400), calendar: utc)
        func key(_ g: GroupBy, _ index: UInt32) -> GroupKey {
            let e = store.entry(index)
            switch g {
            case .kind: return .kind(TypeRegistry.shared.localizedDescription(e.typeIndex), isFolder: false)
            case .dateModified: return .date(b.bucket(forNanoseconds: e.mtime))
            case .size: return .size(Grouping.sizeBucket(bytes: e.size, isFolder: false))
            case .nameFirstLetter, .none: return .letter(Grouping.letterKey(store.name(index)))
            }
        }
        for g in [GroupBy.kind, .dateModified, .size, .nameFirstLetter] {
            let (order, runs) = Grouping.partition(store.order, store: store, by: g, dateBuckets: b, types: .shared)
            XCTAssertEqual(order.count, items.count, "\(g)")
            XCTAssertEqual(Set(order).count, items.count, "\(g): a permutation")
            XCTAssertGreaterThan(runs.count, 1, "\(g)")
            XCTAssertEqual(runs.first?.rows.lowerBound, 0, "\(g)")
            XCTAssertEqual(runs.last?.rows.upperBound, items.count, "\(g)")
            XCTAssertTrue(zip(runs, runs.dropFirst()).allSatisfy { pair in pair.0.rows.upperBound == pair.1.rows.lowerBound },
                          "\(g): runs tile the rows")
            XCTAssertTrue(zip(runs, runs.dropFirst()).allSatisfy { pair in Grouping.groupOrder(pair.0.key, pair.1.key) },
                          "\(g): runs in group order")
            XCTAssertEqual(Set(runs.map(\.key)).count, runs.count, "\(g): one run per key")
            for run in runs {
                let rows = order[run.rows]
                XCTAssertTrue(zip(rows, rows.dropFirst()).allSatisfy { pair in pair.0 < pair.1 }, "\(g) \(run.key): stable")
                for row in stride(from: run.rows.lowerBound, to: run.rows.upperBound, by: 101) {
                    XCTAssertEqual(key(g, order[row]), run.key, "\(g): \(store.name(order[row]))")
                }
            }
        }
    }

    /// Review (P2-09): non-ASCII first letters (CJK, Cyrillic, precomposed and decomposed accents, an ASCII letter
    /// followed by a non-ASCII byte) over 100k rows get the groups `letterKey` gives (the key is cached by the first
    /// grapheme's bytes). The 30 ms budget is `resort.grouped.nameFirstLetter.nonASCII` in macx-bench.
    func testPartition100kNonASCIIFirstLetters() {
        let prefixes = ["日本語", "中文", "한국어", "Привет", "Ωmega", "Äpfel", "A\u{0308}pfel", "e\u{0301}clair", "éclair", "aé", "Ａbc", "１x"]
        let items = (0..<100_000).map { (name: "\(prefixes[$0 % prefixes.count])\(["", " ", "-", "x"][$0 % 4])\($0).txt",
                                         kind: Kind.file, size: Int64($0), mtime: Int64($0)) }
        let store = makeStore(items)
        let b = DateBuckets(now: Date(timeIntervalSince1970: 0), calendar: utc)
        let (order, runs) = Grouping.partition(store.order, store: store, by: .nameFirstLetter, dateBuckets: b, types: .shared)
        for run in runs {
            for row in run.rows { XCTAssertEqual(.letter(Grouping.letterKey(store.name(order[row]))), run.key) }
        }
        XCTAssertEqual(runs.map(\.key), [.letter(.digits), .letter(.letter("A")), .letter(.letter("E")), .letter(.letter("Ω")),
                                          .letter(.letter("П")), .letter(.letter("中")), .letter(.letter("日")), .letter(.letter("한"))]
                       .sorted(by: Grouping.groupOrder))
    }

    /// The grapheme-prefix cache gives the same key as `letterKey` on edge cases: combining marks, emoji sequences,
    /// regional indicators, leading dots, names that end after one scalar.
    func testPartitionLetterKeysMatchLetterKeyOnEdgeCases() {
        let names = ["e\u{0301}", "e\u{0301}\u{0302}x", "e", "é", "🇫🇷x", "🇫🇷🇩🇪", "👩‍💻a", "😀", ".é", "..日", "Ä", "A\u{0308}",
                     "a\u{0308}\u{0301}\u{0302}\u{0303}\u{0304}\u{0305}z", "\u{0301}a", "ß", "ǆa", "ＡＢ", "\r\n", "क्षa", "\u{FFFD}"]
        let store = makeStore(names.enumerated().map { (name: $1, kind: Kind.file, size: Int64($0), mtime: 0) })
        let b = DateBuckets(now: Date(timeIntervalSince1970: 0), calendar: utc)
        let (order, runs) = Grouping.partition(store.order, store: store, by: .nameFirstLetter, dateBuckets: b, types: .shared)
        for run in runs {
            for row in run.rows {
                let name = store.name(order[row])
                XCTAssertEqual(.letter(Grouping.letterKey(name)), run.key, name.debugDescription)
            }
        }
        XCTAssertEqual(runs.map(\.rows.count).reduce(0, +), names.count)
    }
}
