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

    /// Sizes streaming in for a large selection update the total incrementally (§11: "computed incrementally"):
    /// no O(selection) pass per arriving size.
    func testSelectionFolderBytesUpdateIncrementallyAsSizesArrive() async throws {
        let sandbox = try Sandbox(); defer { sandbox.destroy() }
        for name in ["a", "b", "c"] { try sandbox.createDirectory(name) }
        try sandbox.createFile("f.txt", contents: Data(count: 3))
        let env = CoreEnvironment.sandboxed(root: sandbox.root); _ = await env.start()
        let model = try await loadedModel(sandbox.root, env: env)
        defer { model.close() }
        model.setFolderSizesEnabled(true)
        model.select(.all)
        XCTAssertNil(model.selectionSummary.folderBytes)
        let passes = model.selectionSummaryPasses
        let id = { (name: String) in model.identity(atRow: model.row(named: name)!) }
        model.setFolderSizes([id("a"): FolderSize(bytes: 10)])
        XCTAssertNil(model.selectionSummary.folderBytes, "b and c unknown")
        model.setFolderSizes([id("b"): FolderSize(bytes: 20), id("c"): FolderSize(bytes: 30)])
        XCTAssertEqual(model.selectionSummary.folderBytes, 60)
        model.setFolderSizes([id("a"): FolderSize(bytes: 15)])                     // a rescan changes one size
        XCTAssertEqual(model.selectionSummary.folderBytes, 65)
        XCTAssertEqual(model.selectionSummary.bytes, 3)
        XCTAssertEqual(model.selectionSummaryPasses, passes, "sizes arriving never re-walk the selection")
        model.select(.names(["a", "f.txt"]))
        XCTAssertEqual(model.selectionSummary.folderBytes, 15, "a new selection is summed afresh")
        model.setFolderSizesEnabled(false)
        XCTAssertNil(model.selectionSummary.folderBytes)
    }

    func testCoalescedResortWhileSizesStreamIn() async throws {
        let sandbox = try Sandbox(); defer { sandbox.destroy() }
        for name in ["a", "b", "c"] { try sandbox.createDirectory(name) }
        let env = CoreEnvironment.sandboxed(root: sandbox.root); _ = await env.start()
        var ctx = env.folderContext(); ctx.resortCoalescing = .milliseconds(200)
        // A late FSEvents delivery for the directories just created would re-sort through the patch path (not a
        // .reset) and race the coalesced re-sort this test counts.
        ctx.makeWatcher = { _, _, _ in NoopWatcher() }
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
