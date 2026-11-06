import XCTest
@testable import Core
import MacxFS
import MacxFixtures

/// P2-16: sorting by an extended column (Tags, Date Last Opened, Permissions, Owner, Comments).
@MainActor
final class FolderModelExtendedSortTests: XCTestCase {
    private func names(_ model: FolderModel) -> [String] { (0..<model.rowCount).map(model.name(atRow:)) }

    private func wait(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { try await Task.sleep(for: .milliseconds(20)) }
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
}
