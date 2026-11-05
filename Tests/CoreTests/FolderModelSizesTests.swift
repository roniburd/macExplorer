import XCTest
@testable import Core
import MacxFS
import MacxFixtures

@MainActor
final class FolderModelSizesTests: XCTestCase {
    func waitUntil(_ timeout: Duration = .seconds(10), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func testEnableSortSummaryAndDisable() async throws {
        let sandbox = try Sandbox(); defer { sandbox.destroy() }
        try sandbox.createFile("big/a", contents: Data(count: 5_000))
        try sandbox.createFile("small/a", contents: Data(count: 10))
        try sandbox.createFile("f.txt", contents: Data(count: 3))
        let env = CoreEnvironment.sandboxed(root: sandbox.root); _ = await env.start()
        var ctx = env.folderContext(); ctx.resortCoalescing = .zero
        let model = FolderModel(directory: sandbox.root, context: ctx, query: ViewQuery(sort: SortDescriptor(field: .size, ascending: true)))
        defer { model.close() }
        model.start()
        await waitUntil { model.state == .complete }
        XCTAssertEqual((0..<3).map(model.name(atRow:)), ["big", "small", "f.txt"], "Phase 1: folders by name")
        model.setFolderSizesEnabled(true)
        XCTAssertTrue(model.folderSizesEnabled)
        let session = env.folderSizes.attach(to: model)
        await session.waitUntilIdle()
        await waitUntil { model.name(atRow: 0) == "small" }
        XCTAssertEqual((0..<3).map(model.name(atRow:)), ["small", "big", "f.txt"])
        model.select(.names(["big", "f.txt"]))
        XCTAssertEqual(model.selectionSummary.bytes, 3)
        XCTAssertEqual(model.selectionSummary.folderBytes, 5_000)
        model.select(.names(["f.txt"]))
        XCTAssertEqual(model.selectionSummary.folderBytes, 0)
        session.stop()
        var cleared = Set<RowID>()
        let token = model.observe { if case .folderSizes(let ids) = $0 { cleared.formUnion(ids) } }
        model.setFolderSizesEnabled(false)
        token.cancel()
        XCTAssertEqual(cleared.count, 2, "turning sizes off redraws every sized row")
        XCTAssertNil(model.folderSize(atRow: 0))
        XCTAssertNil(model.selectionSummary.folderBytes)
        await waitUntil { model.name(atRow: 0) == "big" }
        XCTAssertEqual((0..<3).map(model.name(atRow:)), ["big", "small", "f.txt"], "sizes off: folders by name again")
    }

    func testSelectionFolderBytesFollowTheToggle() async throws {
        let sandbox = try Sandbox(); defer { sandbox.destroy() }
        try sandbox.createFile("big/a", contents: Data(count: 5_000))
        let env = CoreEnvironment.sandboxed(root: sandbox.root); _ = await env.start()
        let model = try await loadedModel(sandbox.root, env: env)
        defer { model.close() }
        XCTAssertFalse(model.folderSizesEnabled)
        model.select(.names(["big"]))
        XCTAssertNil(model.selectionSummary.folderBytes, "sizes off: nil")
        model.setFolderSizesEnabled(true)
        XCTAssertNil(model.selectionSummary.folderBytes, "a selected folder's size is unknown: nil")
        model.setFolderSizes([model.identity(atRow: 0): FolderSize(bytes: 42)])
        XCTAssertEqual(model.selectionSummary.folderBytes, 42)
    }

    func testCoalescedResortWhileSizesStreamIn() async throws {
        let sandbox = try Sandbox(); defer { sandbox.destroy() }
        for name in ["a", "b", "c"] { try sandbox.createDirectory(name) }
        let env = CoreEnvironment.sandboxed(root: sandbox.root); _ = await env.start()
        var ctx = env.folderContext(); ctx.resortCoalescing = .milliseconds(200)
        let model = FolderModel(directory: sandbox.root, context: ctx, query: ViewQuery(sort: SortDescriptor(field: .size, ascending: true)))
        defer { model.close() }
        model.start()
        await waitUntil { model.state == .complete }
        model.setFolderSizesEnabled(true)
        var resets = 0
        let token = model.observe { if case .changes(let c) = $0, c == .reset { resets += 1 } }
        defer { token.cancel() }
        let ids = (0..<3).map(model.identity(atRow:))
        model.setFolderSizes([ids[0]: FolderSize(bytes: 30)])
        model.setFolderSizes([ids[1]: FolderSize(bytes: 20)])
        model.setFolderSizes([ids[2]: FolderSize(bytes: 10)])
        XCTAssertEqual((0..<3).map(model.name(atRow:)), ["a", "b", "c"], "no re-sort before the coalescing interval")
        await waitUntil { model.name(atRow: 0) == "c" }
        XCTAssertEqual((0..<3).map(model.name(atRow:)), ["c", "b", "a"])
        XCTAssertEqual(resets, 1, "three size updates, one re-sort")
        // A later query change (filter) keeps the size order.
        var query = model.query; query.showHidden = true
        model.setQuery(query)
        await waitUntil { model.query.showHidden && resets == 2 }
        XCTAssertEqual((0..<3).map(model.name(atRow:)), ["c", "b", "a"], "setQuery passes the current extras")
    }
}
