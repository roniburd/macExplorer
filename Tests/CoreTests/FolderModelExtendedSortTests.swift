import XCTest
@testable import Core
import MacxFS
import MacxFixtures

/// P2-16: sorting by an extended column (Tags, Date Last Opened, Permissions, Owner, Comments).
@MainActor
final class FolderModelExtendedSortTests: XCTestCase {
    private func names(_ model: FolderModel) -> [String] { (0..<model.rowCount).map(model.name(atRow:)) }

    /// Fails the test at the caller when `condition` does not hold within `timeout` (a slow xattr read is a timeout,
    /// not a wrong value further down).
    private func wait(_ timeout: Duration = .seconds(30), file: StaticString = #filePath, line: UInt = #line,
                      _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out after \(timeout)", file: file, line: line) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// A model of `sandbox` with no real folder watcher (the tests deliver watcher events themselves: a real
    /// FSEvents delivery of their own xattr writes would re-read at an unpredictable time).
    private func unwatchedModel(_ sandbox: Sandbox) async throws -> FolderModel {
        let env = CoreEnvironment.sandboxed(root: sandbox.root); _ = await env.start()
        var ctx = env.folderContext(); ctx.resortCoalescing = .zero
        ctx.makeWatcher = { _, _, _ in NoopWatcher() }
        let model = FolderModel(directory: sandbox.root, context: ctx, query: ViewQuery())
        model.start()
        addTeardownBlock { @MainActor in model.close() }
        try await wait { model.state == .complete }
        return model
    }

    func testSortByCommentsFoldersFirstMissingLastBothDirections() async throws {
        let sandbox = try Sandbox(); defer { sandbox.destroy() }
        try sandbox.createDirectory("D")
        for n in ["a.txt", "b.txt", "c.txt"] { try sandbox.createFile(n) }
        try sandbox.setFinderComment("zulu", on: "a.txt"); try sandbox.setFinderComment("Alpha", on: "c.txt")
        let env = CoreEnvironment.sandboxed(root: sandbox.root); _ = await env.start()
        let model = try await loadedModel(sandbox.root, env: env)
        addTeardownBlock { @MainActor in model.close() }
        var queries: [ViewQuery] = []
        let token = model.observe { if case .query(let q) = $0 { queries.append(q) } }
        defer { token.cancel() }
        let asc = ViewQuery(sort: SortDescriptor(field: .comments, ascending: true))
        model.setQuery(asc)
        XCTAssertEqual(queries, [asc], ".query is emitted at once")
        try await wait { self.names(model) == ["D", "c.txt", "a.txt", "b.txt"] }
        XCTAssertEqual(names(model), ["D", "c.txt", "a.txt", "b.txt"])
        model.setQuery(ViewQuery(sort: SortDescriptor(field: .comments, ascending: false)))
        try await wait { self.names(model) == ["D", "a.txt", "c.txt", "b.txt"] }
        XCTAssertEqual(names(model), ["D", "a.txt", "c.txt", "b.txt"], "missing stays last descending")
    }

    func testPermissionsSortUsesModeBits() async throws {
        let sandbox = try Sandbox(); defer { sandbox.destroy() }
        for n in ["a", "b", "c"] { try sandbox.createFile(n) }
        try sandbox.setMode("a", 0o644); try sandbox.setMode("b", 0o600); try sandbox.setMode("c", 0o755)
        let env = CoreEnvironment.sandboxed(root: sandbox.root); _ = await env.start()
        let model = try await loadedModel(sandbox.root, env: env)
        addTeardownBlock { @MainActor in model.close() }
        model.setQuery(ViewQuery(sort: SortDescriptor(field: .permissions, ascending: true)))
        try await wait { self.names(model) == ["b", "a", "c"] }
        XCTAssertEqual(names(model), ["b", "a", "c"])
    }

    /// A newer query wins: the load for the extended sort is cancelled and its result never replaces the order.
    func testQueryChangeDuringLoadWins() async throws {
        let sandbox = try Sandbox(); defer { sandbox.destroy() }
        for n in ["a.txt", "b.txt"] { try sandbox.createFile(n) }
        try sandbox.setFinderTags(["zeta"], on: "a.txt"); try sandbox.setFinderTags(["alpha"], on: "b.txt")
        let env = CoreEnvironment.sandboxed(root: sandbox.root); _ = await env.start()
        let model = try await loadedModel(sandbox.root, env: env)
        addTeardownBlock { @MainActor in model.close() }
        model.setQuery(ViewQuery(sort: SortDescriptor(field: .tags, ascending: true)))
        let byName = ViewQuery(sort: SortDescriptor(field: .name, ascending: true))
        model.setQuery(byName)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(model.query, byName)
        XCTAssertEqual(names(model), ["a.txt", "b.txt"])
    }

    /// While sorted by tags, a tag change (watcher re-read) re-sorts.
    func testValueChangeWhileSortedResorts() async throws {
        let sandbox = try Sandbox(); defer { sandbox.destroy() }
        for n in ["a.txt", "b.txt"] { try sandbox.createFile(n) }
        try sandbox.setFinderTags(["alpha"], on: "a.txt"); try sandbox.setFinderTags(["beta"], on: "b.txt")
        let env = CoreEnvironment.sandboxed(root: sandbox.root); _ = await env.start()
        let model = try await loadedModel(sandbox.root, env: env)
        addTeardownBlock { @MainActor in model.close() }
        model.setQuery(ViewQuery(sort: SortDescriptor(field: .tags, ascending: true)))
        model.requestExtendedAttributes(rows: IndexSet(integersIn: 0..<model.rowCount), .tags)
        try await wait { model.extendedAttributes(atRow: 0)?.tags == ["alpha"] }
        XCTAssertEqual(names(model), ["a.txt", "b.txt"])
        try sandbox.setFinderTags(["gamma"], on: "a.txt")
        model.handleWatch(.items(["a.txt"]))
        try await wait { self.names(model) == ["b.txt", "a.txt"] }
        XCTAssertEqual(names(model), ["b.txt", "a.txt"])
    }

    /// Review fix: sorted by Tags with no visible-row request (Tags column hidden), a new tagged file and a retag of
    /// an existing item are read for the sort, and the order updates (no stale "missing" positions).
    func testNewAndRetaggedItemsResortWithoutVisibleRequest() async throws {
        let sandbox = try Sandbox(); defer { sandbox.destroy() }
        for n in ["a.txt", "b.txt"] { try sandbox.createFile(n) }
        try sandbox.setFinderTags(["beta"], on: "a.txt"); try sandbox.setFinderTags(["delta"], on: "b.txt")
        let model = try await unwatchedModel(sandbox)
        model.setQuery(ViewQuery(sort: SortDescriptor(field: .tags, ascending: true)))
        try await wait { model.extendedSortTask == nil && model.sortColumn?.count == 2 }
        XCTAssertEqual(names(model), ["a.txt", "b.txt"])
        XCTAssertNil(model.lastAttributeRequest, "no view asked for attributes")

        try sandbox.createFile("c.txt")
        try sandbox.setFinderTags(["alpha"], on: "c.txt")
        model.handleWatch(.items(["c.txt"]))
        try await wait { self.names(model) == ["c.txt", "a.txt", "b.txt"] }
        XCTAssertEqual(names(model), ["c.txt", "a.txt", "b.txt"], "a new tagged file sorts by its tag, not as missing")

        try sandbox.setFinderTags(["zulu"], on: "a.txt")
        model.handleWatch(.items(["a.txt"]))
        try await wait { self.names(model) == ["c.txt", "b.txt", "a.txt"] }
        XCTAssertEqual(names(model), ["c.txt", "b.txt", "a.txt"], "an off-screen retag re-sorts")
    }

    /// Review fix: leaving an extended sort drops the per-row values loaded for it (memory, §4.4), keeping only the
    /// rows the view last asked for.
    func testLeavingExtendedSortTrimsAttributesToRequestedRows() async throws {
        let sandbox = try Sandbox(); defer { sandbox.destroy() }
        for n in ["a", "b", "c", "d"] { try sandbox.createFile(n) }
        let env = CoreEnvironment.sandboxed(root: sandbox.root); _ = await env.start()
        let model = try await loadedModel(sandbox.root, env: env)
        addTeardownBlock { @MainActor in model.close() }
        model.requestExtendedAttributes(rows: IndexSet(integer: 0), .permissions)
        try await wait { model.extendedAttributes(atRow: 0) != nil }
        model.setQuery(ViewQuery(sort: SortDescriptor(field: .permissions, ascending: true)))
        try await wait { model.extendedSortTask == nil && model.sortColumn?.count == 4 }
        XCTAssertEqual(model.sortColumn?.count, 4)
        model.setQuery(ViewQuery(sort: SortDescriptor(field: .name, ascending: true)))
        XCTAssertEqual(model.attributeTable.count, 1, "only the requested row keeps its attributes")
        XCTAssertNotNil(model.attributeTable[model.identity(atRow: 0)])
        XCTAssertTrue(model.sortValues().isEmpty)
    }

    /// Review fix: the sort values main hands the worker are kept up to date per changed identity, not rebuilt from
    /// the whole attribute table on every re-sort or patch.
    func testSortValuesAreMaintainedIncrementally() async throws {
        let sandbox = try Sandbox(); defer { sandbox.destroy() }
        for n in ["a.txt", "b.txt"] { try sandbox.createFile(n) }
        try sandbox.setFinderComment("one", on: "a.txt")
        let model = try await unwatchedModel(sandbox)
        model.setQuery(ViewQuery(sort: SortDescriptor(field: .comments, ascending: true)))
        try await wait { model.extendedSortTask == nil && model.sortColumn?.count == 2 }
        let builds = model.sortColumnBuilds
        try sandbox.setFinderComment("two", on: "b.txt")
        model.handleWatch(.items(["b.txt"]))
        let two = SortKeys.nameKey("two", isFolder: false)
        try await wait { self.names(model) == ["a.txt", "b.txt"] && model.sortColumn?.key(model.identity(atRow: 1)) == two }
        try sandbox.setFinderComment("zzz", on: "a.txt")
        model.handleWatch(.items(["a.txt"]))
        try await wait { self.names(model) == ["b.txt", "a.txt"] }
        XCTAssertEqual(names(model), ["b.txt", "a.txt"])
        XCTAssertEqual(model.sortColumnBuilds, builds, "no full rebuild of the sort column after changes")
        XCTAssertEqual(model.sortValues().column?.kind, .strings)
        XCTAssertEqual(model.sortValues().column?.count, 2)
    }

    private func sortedModel(_ sandbox: Sandbox, _ field: SortField, rows: Int) async throws -> FolderModel {
        let env = CoreEnvironment.sandboxed(root: sandbox.root); _ = await env.start()
        var ctx = env.folderContext(); ctx.resortCoalescing = .zero
        ctx.makeWatcher = { _, _, _ in NoopWatcher() }        // the tests deliver watcher events themselves
        let model = FolderModel(directory: sandbox.root, context: ctx, query: ViewQuery())
        model.start()
        addTeardownBlock { @MainActor in model.close() }
        try await wait { model.state == .complete && model.rowCount == rows }
        model.setQuery(ViewQuery(sort: SortDescriptor(field: field, ascending: true)))
        try await wait { model.extendedSortTask == nil && model.sortColumn?.count == rows }
        await model.drainQueuedWork()                    // the load's re-sort is queued after extendedSortTask clears
        return model
    }

    /// Review fix (§4.4 memory): sorting by an extended column keeps one compact value per row in the sort column
    /// and no full `ExtendedAttributes` for rows no view asked for.
    func testSortLoadFillsOnlyTheCompactColumn() async throws {
        let sandbox = try Sandbox(); defer { sandbox.destroy() }
        for n in ["a.txt", "b.txt", "c.txt"] { try sandbox.createFile(n) }
        try sandbox.setFinderTags(["beta"], on: "a.txt")
        let model = try await sortedModel(sandbox, .tags, rows: 3)
        XCTAssertEqual(model.sortColumn?.count, 3)
        XCTAssertTrue(model.attributeTable.isEmpty, "no view asked for attributes")
        XCTAssertEqual(model.sortColumn?.key(model.identity(atRow: 0)), SortKeys.nameKey("beta", isFolder: false))
        XCTAssertNil(model.sortColumn?.key(model.identity(atRow: 1)), "no tag: loaded without a value")
        XCTAssertEqual(names(model), ["a.txt", "b.txt", "c.txt"])
    }

    /// Review fix: flipping the direction of a loaded extended sort reads nothing again, and F5 re-reads each
    /// row's sort value once (not once for the invalidation and again for the load that follows the re-read).
    func testToggleReadsNothingAndRefreshReadsEachRowOnce() async throws {
        let sandbox = try Sandbox(); defer { sandbox.destroy() }
        for n in ["a.txt", "b.txt", "c.txt"] { try sandbox.createFile(n) }
        try sandbox.setFinderComment("zulu", on: "a.txt")
        let model = try await sortedModel(sandbox, .comments, rows: 3)
        let reads = model.sortValueReads
        XCTAssertEqual(reads, 3)
        model.setQuery(ViewQuery(sort: SortDescriptor(field: .comments, ascending: false)))
        try await wait { model.extendedSortTask == nil }
        XCTAssertEqual(model.sortValueReads, reads, "the toggle reads nothing")
        model.refresh()
        try await wait { !model.rereadInFlight && model.extendedSortTask == nil && model.sortValueReads > reads }
        await model.drainQueuedWork()                    // the load's re-sort lands
        try await Task.sleep(for: .milliseconds(200))    // negative check below: no second read of any row
        XCTAssertEqual(model.sortValueReads, reads + 3, "F5 re-reads each row once")
        XCTAssertEqual(model.sortColumn?.key(model.identity(atRow: model.row(named: "a.txt")!)),
                       SortKeys.nameKey("zulu", isFolder: false))
        XCTAssertFalse(model.sortColumnRefreshPending)
    }

    /// Review fix: a row the watcher invalidates keeps its sort position while a visible-row read that does not
    /// cover the sort field (Comments column hidden, Tags shown) lands first.
    func testNarrowVisibleReadKeepsTheSortValue() async throws {
        let sandbox = try Sandbox(); defer { sandbox.destroy() }
        for n in ["a.txt", "b.txt", "c.txt"] { try sandbox.createFile(n) }
        try sandbox.setFinderComment("alpha", on: "c.txt")
        let model = try await sortedModel(sandbox, .comments, rows: 3)
        XCTAssertEqual(names(model), ["c.txt", "a.txt", "b.txt"])
        var orders: [[String]] = []
        let token = model.observe { if case .changes = $0 { orders.append(self.names(model)) } }
        defer { token.cancel() }
        model.requestExtendedAttributes(rows: IndexSet(integersIn: 0..<3), .tags)
        try await wait { model.extendedAttributes(atRow: 0) != nil }
        for _ in 0..<5 {
            model.handleWatch(.items(["c.txt"]))
            try await wait { model.staleSortValues.isEmpty && model.staleAttributes.isEmpty }
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNotNil(model.sortColumn?.key(model.identity(atRow: 0)))
        XCTAssertTrue(orders.allSatisfy { $0 == ["c.txt", "a.txt", "b.txt"] }, "\(orders)")
        XCTAssertEqual(names(model), ["c.txt", "a.txt", "b.txt"])
    }

    /// Review fix: entries of a deleted item leave the sort column and the attribute table with the patch that
    /// removes its row.
    func testDeletedItemLeavesTheColumn() async throws {
        let sandbox = try Sandbox(); defer { sandbox.destroy() }
        for n in ["a.txt", "b.txt", "c.txt"] { try sandbox.createFile(n) }
        let model = try await sortedModel(sandbox, .owner, rows: 3)
        model.requestExtendedAttributes(rows: IndexSet(integersIn: 0..<3), .permissions)
        try await wait { model.attributeTable.count == 3 }
        let gone = model.identity(atRow: model.row(named: "c.txt")!)
        try sandbox.remove("c.txt")
        model.handleWatch(.items(["c.txt"]))
        try await wait { model.rowCount == 2 }
        XCTAssertEqual(model.sortColumn?.count, 2)
        XCTAssertEqual(model.sortColumn?.contains(gone), false)
        XCTAssertNil(model.attributeTable[gone])
    }
}
