@testable import Core
import Foundation
@testable import MacxFS
import XCTest

/// FolderWorker.patch diffs by storage index instead of re-matching every identity (§4.4 FSEvent → UI updated
/// < 150 ms in 100k folders). Its diff must equal the general StoreDiff.diff of the same two stores.
final class FolderWorkerPatchTests: XCTestCase {
    private let types = TypeRegistry()

    private func loaded(_ names: [String], hiddenEvery: Int = 0) -> EntryStore {
        var store = EntryStore(identityMode: .objectID)
        store.append(TestBatch.make(.initial, names.enumerated().map {
            TestBatch.Item(name: $0.element, id: UInt64($0.offset + 1), size: Int64($0.offset % 7),
                           hidden: hiddenEvery > 0 && $0.offset % hiddenEvery == 0)
        }))
        let keys = SortKeys.nameKeys(store, range: 0..<store.count)
        store.setOrder(Sorter.permutation(store, nameKeys: keys, searchKeys: nil, query: ViewQuery(), kindRanks: types.kindRanks().ranks))
        return store
    }

    private func check(_ old: EntryStore, _ result: ItemReadResult, query: ViewQuery = ViewQuery(),
                       file: StaticString = #filePath, line: UInt = #line) async {
        let worker = FolderWorker(types: types)
        let patched = await worker.patch(old, tag: 0, result: result, query: query, caseSensitive: false)
        let general = StoreDiff.diff(old: old, new: patched.store)
        XCTAssertEqual(patched.diff, general, file: file, line: line)
        DiffChecker.check(old: old, new: patched.store, result: patched.diff, file: file, line: line)
    }

    private func result(_ items: [TestBatch.Item], missing: [String] = [], errors: [String: Int32] = [:]) -> ItemReadResult {
        ItemReadResult(batch: TestBatch.make(.initial, items), missing: missing, errors: errors)
    }

    private let names = (0..<200).map { "file-\($0).txt" }

    func testInsertMatchesGeneralDiff() async {
        await check(loaded(names), result([TestBatch.Item(name: "file-50a.txt", id: 9_000)]))
    }

    func testRemoveAndChangeMatchGeneralDiff() async {
        await check(loaded(names), result([TestBatch.Item(name: "file-7.txt", id: 8, size: 99)],
                                          missing: ["file-3.txt", "FILE-150.TXT", "nope"]))
    }

    func testAtomicSaveReplacementMatchesGeneralDiff() async {
        await check(loaded(names), result([TestBatch.Item(name: "file-10.txt", id: 7_777), TestBatch.Item(name: "new", id: 7_778)]))
    }

    func testErrorsAndHiddenRowsMatchGeneralDiff() async {
        await check(loaded(names, hiddenEvery: 5), result([TestBatch.Item(name: "file-12.txt", id: 13, hidden: true),
                                                           TestBatch.Item(name: "file-15.txt", id: 16, hidden: false)],
                                                          errors: ["file-20.txt": EACCES, "file-21.txt": EIO]))
    }

    func testSizeSortMoveMatchesGeneralDiff() async {
        await check(loaded(names), result([TestBatch.Item(name: "file-1.txt", id: 2, size: 1_000),
                                           TestBatch.Item(name: "file-199.txt", id: 200, size: 0)]),
                    query: ViewQuery(sort: SortDescriptor(field: .size, ascending: true)))
    }

    func testRandomPatchesMatchGeneralDiff() async {
        var generator = SystemRandomNumberGenerator()
        for round in 0..<20 {
            let old = loaded(names, hiddenEvery: round % 3 == 0 ? 4 : 0)
            var items: [TestBatch.Item] = []
            var missing: [String] = []
            var errors: [String: Int32] = [:]
            for _ in 0..<Int.random(in: 1...30, using: &generator) {
                let i = Int.random(in: 0..<names.count, using: &generator)
                switch Int.random(in: 0..<5, using: &generator) {
                case 0: items.append(TestBatch.Item(name: names[i], id: UInt64(i + 1), size: Int64.random(in: 0..<9, using: &generator)))
                case 1: items.append(TestBatch.Item(name: names[i], id: UInt64(10_000 + i)))          // replaced
                case 2: items.append(TestBatch.Item(name: "added-\(round)-\(i)", id: UInt64(20_000 + i)))
                case 3: missing.append(names[i])
                default: errors[names[i]] = EIO
                }
            }
            var seen = Set<String>()
            items = items.filter { seen.insert($0.name.lowercased()).inserted }
            missing = missing.filter { seen.insert($0.lowercased()).inserted }
            errors = errors.filter { seen.insert($0.key.lowercased()).inserted }
            await check(old, result(items, missing: missing, errors: errors),
                        query: ViewQuery(sort: SortDescriptor(field: round % 2 == 0 ? .name : .size, ascending: round % 4 < 2)))
        }
    }
}
