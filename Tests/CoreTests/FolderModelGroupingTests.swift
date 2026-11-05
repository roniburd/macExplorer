import XCTest
import Synchronization
@testable import Core
import MacxFS
import MacxFixtures

/// Records what a model publishes: "groups:<n>", "reset", "reload" (reload-only sets) or "changes" (incremental).
@MainActor
private final class GroupingLog {
    private(set) var entries: [String] = []
    private var token: ObserverToken?
    init(_ model: FolderModel) {
        token = model.observe { [weak self] e in
            switch e {
            case .groups(let r): self?.entries.append("groups:\(r.count)")
            case .changes(let c):
                if c.changes == [.reset] {
                    self?.entries.append("reset")
                } else if c.changes.allSatisfy({ if case .reload = $0 { true } else { false } }) {
                    self?.entries.append("reload")
                } else {
                    self?.entries.append("changes")
                }
            default: break
            }
        }
    }
    func clear() { entries = [] }
    deinit { token?.cancel() }
}

@MainActor
final class FolderModelGroupingTests: XCTestCase {
    var sandbox: Sandbox!
    var env: CoreEnvironment!

    override func setUp() async throws {
        sandbox = try Sandbox()
        addTeardownBlock { [sandbox] in sandbox?.destroy() }
        env = CoreEnvironment.sandboxed(root: sandbox.root)
        _ = await env.start()
    }

    private func load(_ query: ViewQuery? = nil) async throws -> FolderModel {
        let model = try await loadedModel(sandbox.root, env: env, query: query)
        addTeardownBlock { @MainActor in model.close() }
        return model
    }

    private func waitUntil(_ what: String, timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { XCTFail("timed out: \(what)"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func names(_ model: FolderModel) -> [String] { (0..<model.rowCount).map(model.name(atRow:)) }

    private func run(of name: String, in model: FolderModel) -> GroupRun? {
        guard let row = model.row(named: name) else { return nil }
        return model.groups.first { $0.rows.contains(row) }
    }

    func testKindGroupingPublishesGroupsThenResetAndOrdersFolderFirst() async throws {
        try sandbox.createDirectory("sub"); try sandbox.createFile("a.txt"); try sandbox.createFile("b.txt"); try sandbox.createFile("c.png")
        let model = try await load()
        XCTAssertEqual(model.grouping, .none)
        let log = GroupingLog(model)
        model.setGrouping(.kind)
        XCTAssertEqual(model.grouping, .kind)
        try await waitUntil("grouped") { !model.groups.isEmpty }
        XCTAssertEqual(Array(log.entries.prefix(2)), ["groups:3", "reset"])
        XCTAssertEqual(model.groups.first?.key, .kind(TypeRegistry.shared.localizedDescription(TypeRegistry.folderIndex), isFolder: true))
        XCTAssertEqual(model.name(atRow: 0), "sub")
        let txtRun = try XCTUnwrap(run(of: "a.txt", in: model))
        XCTAssertTrue(txtRun.rows.contains(model.row(named: "b.txt")!))
        XCTAssertFalse(txtRun.rows.contains(model.row(named: "c.png")!))
        XCTAssertEqual(model.groups.map(\.rows.count).reduce(0, +), model.rowCount)
        log.clear()
        model.setGrouping(.none)
        try await waitUntil("ungrouped") { model.groups.isEmpty && log.entries.contains("reset") }
        XCTAssertEqual(log.entries, ["groups:0", "reset"])
        XCTAssertEqual(names(model), ["sub", "a.txt", "b.txt", "c.png"])
    }

    func testSortAppliesInsideEachGroupAndResortKeepsGroups() async throws {
        try sandbox.createFile("a.txt"); try sandbox.createFile("b.txt"); try sandbox.createFile("c.png"); try sandbox.createFile("d.png")
        let model = try await load()
        model.setGrouping(.kind)
        try await waitUntil("grouped") { model.groups.count == 2 }
        let ascending = names(model)
        var query = model.query
        query.sort.ascending.toggle()
        model.setQuery(query)
        try await waitUntil("re-sorted") { self.names(model) != ascending }
        XCTAssertEqual(model.groups.count, 2, "a re-sort keeps the groups")
        for run in model.groups {
            let inGroup = run.rows.map(model.name(atRow:))
            XCTAssertEqual(inGroup, inGroup.sorted(by: >), "descending name order inside \(run.key)")
        }
    }

    func testWatcherInsertLandsInItsGroupAndKeepsSelection() async throws {
        try sandbox.createFile("a.txt"); try sandbox.createFile("z.png"); try sandbox.createFile("b.txt")
        let model = try await load()
        model.setGrouping(.kind)
        try await waitUntil("grouped") { !model.groups.isEmpty }
        model.select(.names(["b.txt"]))
        let selected = model.identity(atRow: model.row(named: "b.txt")!)
        let log = GroupingLog(model)
        try sandbox.createFile("a2.txt")                     // sandbox write, picked up by the Watcher
        try await waitUntil("a2.txt listed", timeout: .seconds(20)) { model.row(named: "a2.txt") != nil }
        let txtRun = try XCTUnwrap(run(of: "a.txt", in: model))
        XCTAssertTrue(txtRun.rows.contains(model.row(named: "a2.txt")!))
        XCTAssertEqual(model.selection.ids, [selected])
        XCTAssertEqual(model.selection.rows, IndexSet([model.row(named: "b.txt")!]))
        XCTAssertFalse(log.entries.contains("changes"), "grouped models publish resets, never incremental inserts")
        XCTAssertTrue(log.entries.contains("reset"))
    }

    func testLocalChangeAcrossASizeBoundaryRegroupsEvenWhenTheOrderIsUnchanged() async throws {
        try sandbox.createFile("a.txt"); try sandbox.createFile("b.txt")
        let model = try await load()
        model.setGrouping(.size)
        try await waitUntil("grouped") { model.groups.count == 1 }
        XCTAssertEqual(model.groups.map(\.key), [.size(.tiny)])
        let log = GroupingLog(model)
        try sandbox.overwrite("b.txt", contents: Data(count: 20_000))
        model.applyLocalChange(LocalChange(directory: sandbox.root, modified: ["b.txt"]))
        try await waitUntil("regrouped") { model.groups.count == 2 }
        XCTAssertEqual(model.groups.map(\.key), [.size(.tiny), .size(.small)])
        XCTAssertEqual(names(model), ["a.txt", "b.txt"])
        XCTAssertTrue(log.entries.contains("groups:2"))
        XCTAssertFalse(log.entries.contains("changes"))
    }

    func testRefreshOfGroupedFolderKeepsGroupsAndAddsNewItemsToTheirGroup() async throws {
        try sandbox.createDirectory("dir"); try sandbox.createFile("a.txt")
        let model = try await load()
        model.setGrouping(.kind)
        try await waitUntil("grouped") { model.groups.count == 2 }
        try sandbox.createDirectory("dir2")
        model.refresh()
        try await waitUntil("dir2 listed") { model.row(named: "dir2") != nil }
        XCTAssertEqual(Array(names(model).prefix(2)), ["dir", "dir2"], "the new folder lands in the Folder group")
        XCTAssertEqual(model.groups.first?.rows, 0..<2)
    }

    func testGroupingSetBeforeTheListingCompletesIsApplied() async throws {
        for i in 0..<50 { try sandbox.createFile("f\(i).\(i.isMultiple(of: 2) ? "txt" : "png")") }
        try sandbox.createDirectory("sub")
        let model = env.makeFolderModel(sandbox.root)
        addTeardownBlock { @MainActor in model.close() }
        model.setGrouping(.kind)
        model.start()
        try await waitUntil("complete and grouped") { model.state == .complete && model.groups.count == 3 }
        XCTAssertEqual(model.name(atRow: 0), "sub")
        XCTAssertEqual(model.groups.map(\.rows.count).reduce(0, +), 51)
    }

    func testDateGroupingUsesInjectedClockAndRegroupsForNewDay() async throws {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!; cal.firstWeekday = 1
        let clock = Mutex(ISO8601DateFormatter().date(from: "2026-11-18T15:00:00Z")!)
        try sandbox.createFile("today.txt"); try sandbox.createFile("yday.txt")
        try sandbox.setModificationDate(ISO8601DateFormatter().date(from: "2026-11-18T10:00:00Z")!, on: "today.txt")
        try sandbox.setModificationDate(ISO8601DateFormatter().date(from: "2026-11-17T10:00:00Z")!, on: "yday.txt")
        var ctx = env.folderContext()
        ctx.now = { clock.withLock { $0 } }
        ctx.calendar = cal
        let model = FolderModel(directory: sandbox.root, context: ctx, query: ViewQuery())
        addTeardownBlock { @MainActor in model.close() }
        model.start()
        try await waitUntil("complete") { model.state == .complete }
        model.setGrouping(.dateModified)
        try await waitUntil("two groups") { model.groups.count == 2 }
        XCTAssertEqual(model.groups.map(\.key), [.date(.today), .date(.yesterday)])
        XCTAssertEqual(names(model), ["today.txt", "yday.txt"])
        clock.withLock { $0 = $0.addingTimeInterval(86_400) }
        model.regroupForNewDay()
        try await waitUntil("next day") { model.groups.first?.key == .date(.yesterday) }
        XCTAssertEqual(model.groups.map(\.key), [.date(.yesterday), .date(.earlierThisWeek)])
    }

    func testRegroupForNewDayIsANoOpUnlessGroupedByDate() async throws {
        try sandbox.createFile("a.txt")
        let model = try await load()
        model.setGrouping(.kind)
        try await waitUntil("grouped") { model.groups.count == 1 }
        let log = GroupingLog(model)
        model.regroupForNewDay()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(log.entries, [])
    }

    func testDayTimerIsCancelledByCloseAndGroupingChange() async throws {
        try sandbox.createFile("a.txt")
        let model = try await load()
        model.setGrouping(.dateModified)
        XCTAssertTrue(model.hasDayTimer)
        model.setGrouping(.kind)
        XCTAssertFalse(model.hasDayTimer)
        model.setGrouping(.dateModified)
        XCTAssertTrue(model.hasDayTimer)
        model.close()
        XCTAssertFalse(model.hasDayTimer)
    }
}
