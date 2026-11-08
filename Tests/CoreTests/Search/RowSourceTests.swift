import XCTest
@testable import Core
@testable import MacxFS
import MacxFixtures

@MainActor
final class RowSourceTests: XCTestCase {
    var sandbox: Sandbox!
    var env: CoreEnvironment!

    override func setUp() async throws {
        sandbox = try Sandbox()
        let s = sandbox!
        addTeardownBlock { s.destroy() }
        env = CoreEnvironment.sandboxed(root: sandbox.root)
    }

    /// Polls until `condition` holds; fails at the caller after `timeout` (a real folder load on a slow runner).
    func waitUntil(_ timeout: Duration = .seconds(30), file: StaticString = #filePath, line: UInt = #line,
                   _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out", file: file, line: line) }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testFolderModelConformsAndMapsEvents() async throws {
        try sandbox.createDirectory("dir")
        for n in ["b.txt", "a.txt", "c.txt"] { try sandbox.createFile("dir/\(n)") }
        let model = env.makeFolderModel(sandbox.url("dir"))
        let source: any RowSource = model
        var events: [String] = []
        let token = source.observeRows { e in
            switch e {
            case .changes: events.append("changes")
            case .selection: events.append("selection")
            case .beginRename: events.append("rename")
            }
        }
        defer { token.cancel(); model.close() }
        model.start()
        await waitUntil { model.state == .complete && source.rowCount == 3 }
        XCTAssertEqual((0..<3).map { source.name(atRow: $0) }, ["a.txt", "b.txt", "c.txt"])
        XCTAssertEqual((0..<3).map { source.displayName(atRow: $0) }, ["a.txt", "b.txt", "c.txt"])
        XCTAssertEqual(source.parentURL(atRow: 0).standardizedFileURL, sandbox.url("dir").standardizedFileURL)
        XCTAssertFalse(source.showsPathColumn)
        XCTAssertEqual(source.sortDescriptor, model.query.sort)
        source.select(.set([1], cursor: 1))
        XCTAssertEqual(source.selectedURLs.map(\.lastPathComponent), ["b.txt"])
        source.setSortDescriptor(SortDescriptor(field: .name, ascending: false))
        await waitUntil { source.name(atRow: 0) == "c.txt" }
        XCTAssertEqual(model.query.sort, SortDescriptor(field: .name, ascending: false))
        XCTAssertEqual(source.selectedURLs.map(\.lastPathComponent), ["b.txt"])   // selection follows identity
        XCTAssertTrue(events.contains("changes"))
        XCTAssertTrue(events.contains("selection"))
    }

    func testSelectionApplyAndReconcileOnAnArbitraryRowSpace() {
        var ids = ["/a", "/b", "/c", "/d"]
        func space() -> SelectionRowSpace {
            let current = ids
            return SelectionRowSpace(count: current.count, identity: { .name(current[$0]) },
                                     row: { id in if case .name(let p) = id { current.firstIndex(of: p) } else { nil } },
                                     rowsNamed: { names in
                                         IndexSet(names.compactMap { n in current.firstIndex { ($0 as NSString).lastPathComponent == n } })
                                     })
        }
        var sel = Selection.empty
        sel.apply(.set([1], cursor: 1), in: space())
        sel.apply(.extend(to: 3), in: space())
        XCTAssertEqual(sel.rows, IndexSet(1...3))
        sel.apply(.toggle(2), in: space())
        XCTAssertEqual(sel.ids, [.name("/b"), .name("/d")])
        ids = ["/d", "/a", "/b"]                       // re-sorted and /c removed
        sel.reconcile(in: space())
        XCTAssertEqual(sel.rows, IndexSet([0, 2]))
        sel.apply(.names(["a"]), in: space())
        XCTAssertEqual(sel.ids, [.name("/a")])
        sel.apply(.invert, in: space())
        XCTAssertEqual(sel.rows, IndexSet([0, 2]))
    }

    func testReplaceCurrentDropsMatchingBackEntry() {
        let folder = URL(filePath: "/tmp/macx-tests-x/f", directoryHint: .isDirectory)
        let s1 = URL(string: "x-macexplorer-search:?v=1&q=AAA")!
        let s2 = URL(string: "x-macexplorer-search:?v=1&q=BBB")!
        var h = NavigationHistory(current: folder)
        h.visit(s1)
        h.replaceCurrent(s2)                           // retyping
        XCTAssertEqual(h.current, s2)
        XCTAssertEqual(h.backList, [folder])
        h.replaceCurrent(folder)                       // clearing the search
        XCTAssertEqual(h.current, folder)
        XCTAssertEqual(h.backList, [])
        XCTAssertFalse(h.canGoBack)
    }

    func testReplaceCurrentKeepsForwardListAndComparesFolderPathsLexically() {
        let a = URL(filePath: "/tmp/macx-tests-x/a", directoryHint: .isDirectory)
        let b = URL(filePath: "/tmp/macx-tests-x/b", directoryHint: .isDirectory)
        let search = URL(string: "x-macexplorer-search:?v=1&q=AAA")!
        var h = NavigationHistory(current: a)
        h.visit(b)
        _ = h.goBack()                                 // current a, forward [b]
        h.visit(search)                                // clears forward
        h.visit(b)
        _ = h.goBack()                                 // current search, back [a], forward [b]
        h.replaceCurrent(URL(filePath: "/tmp/macx-tests-x/a"))   // no trailing slash: still the same folder
        XCTAssertEqual(h.backList, [])
        XCTAssertEqual(h.forwardList, [b])
    }

    func testVisitDistinguishesSearchURLs() {
        let folder = URL(filePath: "/tmp/macx-tests-x/f", directoryHint: .isDirectory)
        let s1 = URL(string: "x-macexplorer-search:?v=1&q=AAA")!
        let s2 = URL(string: "x-macexplorer-search:?v=1&q=BBB")!
        var h = NavigationHistory(current: folder)
        h.visit(s1)
        h.visit(s2)                                    // a different search is a new entry, not "visiting current"
        XCTAssertEqual(h.current, s2)
        XCTAssertEqual(h.backList, [folder, s1])
        h.visit(s2)
        XCTAssertEqual(h.backList, [folder, s1])
    }

    func testObserveAllSeesEveryDirectory() {
        let bus = ChangeBus()
        var seen: [String] = []
        let token = bus.observeAll { seen.append($0.directory.lastPathComponent) }
        defer { token.cancel() }
        bus.post([LocalChange(directory: URL(filePath: "/x/one"), removed: ["a"]),
                  LocalChange(directory: URL(filePath: "/x/two"), added: ["b"])])
        XCTAssertEqual(seen, ["one", "two"])
    }
}
