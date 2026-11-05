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

    func testPartitionOfSubsetKeepsOnlyGivenRows() {
        let store = makeStore([("x.txt", .file, 1, 0), ("y.txt", .file, 1, 0), ("z.png", .file, 1, 0)])
        let b = DateBuckets(now: Date(timeIntervalSince1970: 0), calendar: utc)
        let (order, runs) = Grouping.partition([2, 0], store: store, by: .kind, dateBuckets: b, types: .shared)
        XCTAssertEqual(Set(order), [0, 2])
        XCTAssertEqual(runs.count, 2)
    }

    func testPartition100kWithinDebugBudget() {
        let items = (0..<100_000).map { (name: "file \($0 % 977) \($0).\(["txt", "png", "swift", "md"][$0 % 4])", kind: Kind.file, size: Int64($0 * 37), mtime: Int64($0) * 86_400_000_000_000) }
        let store = makeStore(items)
        let b = DateBuckets(now: Date(timeIntervalSince1970: 100_000 * 86_400), calendar: utc)
        for g in [GroupBy.kind, .dateModified, .size, .nameFirstLetter] {
            let start = ContinuousClock.now
            _ = Grouping.partition(store.order, store: store, by: g, dateBuckets: b, types: .shared)
            let elapsed = ContinuousClock.now - start
            XCTAssertLessThan(elapsed, .milliseconds(120), "\(g): 4x the 30 ms re-sort budget in debug")
        }
    }
}
