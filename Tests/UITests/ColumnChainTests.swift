import XCTest
import Synchronization
@testable import UI
@testable import Core
import MacxFS
import MacxFixtures

final class WatchCounter: Sendable { let started = Mutex(0); let stopped = Mutex(0) }
final class CountingWatcher: ContentWatching {
    let counter: WatchCounter
    init(_ c: WatchCounter) { counter = c }
    func start() { counter.started.withLock { $0 += 1 } }
    func stop() { counter.stopped.withLock { $0 += 1 } }
    var lastEventID: UInt64 { 0 }
}

@MainActor
final class ColumnChainTests: XCTestCase {
    var sandbox: Sandbox!
    var env: CoreEnvironment!
    let counter = WatchCounter()
    var created: [FolderModel] = []

    override func setUp() async throws {
        sandbox = try Sandbox(); addTeardownBlock { [sandbox] in sandbox?.destroy() }
        try sandbox.createFile("A/B/c.txt", contents: Data(count: 1))
        try sandbox.createFile("A/x.txt", contents: Data(count: 1))
        try sandbox.createFile("r.txt", contents: Data(count: 1))
        env = CoreEnvironment.sandboxed(root: sandbox.root); _ = await env.start()
        addTeardownBlock { @MainActor [unowned self] in created.forEach { $0.close() } }
    }

    func factory() -> ColumnChain.ModelFactory {
        { [unowned self] url in
            var ctx = env.folderContext()
            ctx.makeWatcher = { [counter] _, _, _ in CountingWatcher(counter) }
            let m = FolderModel(directory: url, context: ctx, query: ViewQuery())
            created.append(m)
            return m
        }
    }

    func settle(_ chain: ColumnChain, _ timeout: TimeInterval = 3) async {
        let end = Date().addingTimeInterval(timeout)
        while chain.models.contains(where: { $0.state != .complete }) && Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    }

    func names(_ chain: ColumnChain) -> [String] { chain.models.map { $0.directory.standardizedFileURL.lastPathComponent } }

    func testSingleFolderSelectionOpensChildAndFileTruncates() async {
        let chain = ColumnChain(root: sandbox.root, makeModel: factory())
        await settle(chain)
        chain.models[0].select(.names(["A"]))
        XCTAssertEqual(names(chain), [sandbox.root.standardizedFileURL.lastPathComponent, "A"])
        await settle(chain)
        chain.models[1].select(.names(["B"]))
        XCTAssertEqual(names(chain).suffix(2), ["A", "B"])
        chain.models[1].select(.names(["x.txt"]))
        XCTAssertEqual(names(chain).count, 2, "file selection closes deeper columns")
        chain.models[0].select(.names(["A", "r.txt"]))
        XCTAssertEqual(chain.models.count, 1, "multi-selection closes deeper columns")
    }

    func testReselectingTheSameFolderKeepsItsColumn() async {
        let chain = ColumnChain(root: sandbox.root, makeModel: factory())
        await settle(chain)
        chain.models[0].select(.names(["A"]))
        let child = chain.models[1]
        chain.models[0].select(.set(IndexSet(integer: chain.models[0].row(named: "A")!), cursor: nil))
        XCTAssertTrue(chain.models[1] === child, "the same folder keeps its column")
    }

    func testMoveRightLeftAndUp() async {
        let chain = ColumnChain(root: sandbox.url("A"), makeModel: factory())
        await settle(chain)
        chain.models[0].select(.names(["B"]))
        await settle(chain)
        XCTAssertTrue(chain.moveRight())
        XCTAssertEqual(chain.activeIndex, 1)
        XCTAssertEqual(chain.activeModel.selectedURLs.map(\.lastPathComponent), ["c.txt"], "first row selected on entry")
        XCTAssertFalse(chain.moveRight(), "a file opens no further column")
        XCTAssertTrue(chain.moveLeft())
        XCTAssertEqual(chain.activeIndex, 0)
        chain.up()
        await settle(chain)
        XCTAssertEqual(chain.models[0].directory.standardizedFileURL, sandbox.root.standardizedFileURL)
        XCTAssertEqual(chain.models[0].selectedURLs.map(\.lastPathComponent), ["A"])
        XCTAssertEqual(names(chain).last, "A", "old root reopens as column 1")
    }

    func testDetachActiveClosesOthersAndKeepsActive() async {
        let chain = ColumnChain(root: sandbox.root, makeModel: factory())
        await settle(chain)
        chain.models[0].select(.names(["A"]))
        await settle(chain)
        chain.moveRight()
        let active = chain.activeModel
        let kept = chain.detachActive()
        XCTAssertTrue(kept === active)
        XCTAssertTrue(chain.models.isEmpty)
    }

    // Review Focus 5
    func testRapidSelectionInColumnClosesIntermediateModels() async throws {
        for i in 0..<50 { try sandbox.createDirectory(String(format: "many/d%02d", i)) }
        let chain = ColumnChain(root: sandbox.url("many"), makeModel: factory())
        await settle(chain)
        for row in 0..<50 { chain.models[0].select(.set(IndexSet(integer: row), cursor: row)) }   // held ↓
        XCTAssertEqual(chain.models.count, 2)
        XCTAssertEqual(names(chain).last, "d49")
        XCTAssertEqual(created.count, 51, "root + one model per visited folder")
        await settle(chain)
        try await Task.sleep(for: .milliseconds(300))           // let any late batches arrive
        XCTAssertEqual(chain.models[0].selectedURLs.map(\.lastPathComponent), ["d49"], "active column untouched")
        XCTAssertEqual(chain.models.count, 2)
        let live = counter.started.withLock { $0 } - counter.stopped.withLock { $0 }
        XCTAssertEqual(live, 2, "only the two visible columns still watch")
    }
}

extension ColumnChainTests {
    func testSessionColumnsModeAdoptsAndDetachesTheModel() async {
        let session = BrowserSession(environment: env, initialURL: sandbox.root)
        defer { session.close() }
        let original = session.folder
        session.updateViewState { $0.mode = .columns }
        XCTAssertTrue(session.columnChain?.models.first === original, "entering columns re-reads nothing")
        let end = Date().addingTimeInterval(3)
        while session.folder.state != .complete && Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
        session.columnChain!.models[0].select(.names(["A"]))
        while session.columnChain!.models.count < 2 && Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
        session.columnChain!.moveRight()
        XCTAssertEqual(session.folder.directory.lastPathComponent, "A", "session follows the active column")
        session.updateViewState { $0.mode = .details }
        XCTAssertNil(session.columnChain)
        XCTAssertEqual(session.folder.directory.lastPathComponent, "A")
        XCTAssertEqual(session.viewMode, .details)
        session.navigate(to: sandbox.root)
        XCTAssertEqual(session.viewMode, .columns, "the root still remembers Columns")
        XCTAssertEqual(session.columnChain?.models.count, 1)
    }

    func testSessionColumnsSortAppliesToEveryColumnAndNavigationReroots() async {
        let session = BrowserSession(environment: env, initialURL: sandbox.url("A"))
        defer { session.close() }
        session.updateViewState { $0.mode = .columns }        // A remembers Columns
        session.navigate(to: sandbox.root)
        XCTAssertNil(session.columnChain, "the root has no record: the default mode")
        session.updateViewState { $0.mode = .columns }
        let end = Date().addingTimeInterval(3)
        while session.folder.state != .complete && Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
        session.columnChain!.models[0].select(.names(["A"]))
        var sort = session.viewState.sort
        sort.ascending.toggle()
        session.updateViewState { $0.sort = sort }
        XCTAssertEqual(session.columnChain!.models.map(\.query.sort), [sort, sort])
        let chain = session.columnChain!
        session.navigate(to: sandbox.url("A"), selecting: "B")
        XCTAssertTrue(session.columnChain === chain, "navigation in Columns reroots the same chain")
        XCTAssertEqual(session.columnChain!.models.first?.directory.lastPathComponent, "A")
        XCTAssertTrue(session.folder === session.columnChain!.models.first)
        while session.columnChain!.models.count < 2 && Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(session.columnChain!.models.last?.directory.lastPathComponent, "B", "selecting: applies once listed")
        session.navigate(to: sandbox.url("A/B"))
        XCTAssertNil(session.columnChain, "a folder without a Columns record leaves Columns")
        XCTAssertEqual(session.viewMode, .details)
        XCTAssertEqual(session.folder.directory.lastPathComponent, "B")
    }

    func testChainRerootAtTheRootRetargetsTheSessionAndRecordsHistory() async {
        let session = BrowserSession(environment: env, initialURL: sandbox.url("A"))
        defer { session.close() }
        session.updateViewState { $0.mode = .columns }
        session.columnChain!.up()
        XCTAssertEqual(session.locator.path, FolderViewLocator(url: sandbox.root, volume: nil, fileID: nil).path)
        XCTAssertEqual(session.viewMode, .columns)
        XCTAssertTrue(session.folder === session.columnChain!.models.first)
        XCTAssertEqual(session.history.current.standardizedFileURL, sandbox.root.standardizedFileURL)
        let end = Date().addingTimeInterval(3)
        while session.columnChain!.models.count < 2 && Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(session.columnChain!.models.last?.directory.lastPathComponent, "A")
    }

    // Review fix (P2-18): renaming the selected folder in place keeps its row (and RowID on objectID volumes), so
    // no `.selection` is sent; the child column must still follow the new name.
    func testRenamingTheSelectedFolderInPlaceRetargetsItsColumn() async throws {
        let chain = ColumnChain(root: sandbox.url("A"), makeModel: factory())
        await settle(chain)
        chain.models[0].select(.names(["B"]))
        await settle(chain)
        XCTAssertEqual(names(chain), ["A", "B"])
        try FileManager.default.moveItem(at: sandbox.url("A/B"), to: sandbox.url("A/B2"))   // sandbox only
        chain.models[0].refresh()                     // the counting watcher sends no events: re-read by hand
        let end = Date().addingTimeInterval(3)
        while names(chain).last != "B2" && Date() < end { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(chain.models[0].selectedURLs.map(\.lastPathComponent), ["B2"])
        XCTAssertEqual(names(chain), ["A", "B2"], "the child column follows the renamed folder")
        XCTAssertEqual(chain.models.last?.directory.resolvingSymlinksInPath().path,
                       sandbox.url("A/B2").resolvingSymlinksInPath().path)
    }

    // Review fix (P2-18): ⌘↑ at the column root keeps Columns in memory only; the parent's own mode is not rewritten.
    func testChainRerootDoesNotPersistColumnsForTheParent() async {
        let session = BrowserSession(environment: env, initialURL: sandbox.url("A"))
        defer { session.close() }
        session.updateViewState { $0.mode = .columns }
        session.columnChain!.up()
        XCTAssertEqual(session.viewMode, .columns)
        XCTAssertEqual(session.viewState.mode, .columns)
        let other = BrowserSession(environment: env, initialURL: sandbox.root)
        defer { other.close() }
        XCTAssertNotEqual(other.viewMode, .columns, "the parent's stored mode is untouched")
        session.reloadViewState()
        XCTAssertEqual(session.viewMode, .columns, "reloading the state keeps the window in Columns")
        var sort = session.viewState.sort
        sort.ascending.toggle()
        session.updateViewState { $0.sort = sort }   // a real user change while the parent is the root: saved
        let third = BrowserSession(environment: env, initialURL: sandbox.root)
        defer { third.close() }
        XCTAssertEqual(third.viewState.sort, sort)
    }

    // Review fix (P2-18): the search filter follows the active column and clears on the column it leaves.
    func testActivationChangeClearsThePreviousColumnsFilter() async {
        let session = BrowserSession(environment: env, initialURL: sandbox.root)
        defer { session.close() }
        session.updateViewState { $0.mode = .columns }
        let end = Date().addingTimeInterval(3)
        while session.folder.state != .complete && Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
        let chain = session.columnChain!
        chain.models[0].select(.names(["A"]))
        let root = chain.models[0]
        var query = root.query
        query.filter = "A"
        root.setQuery(query)
        XCTAssertTrue(chain.moveRight())
        XCTAssertTrue(session.folder === chain.models[1])
        XCTAssertEqual(root.query.filter, "", "the column that lost activation is unfiltered")
    }

    // Review fix (P2-18): a deeper column whose folder is gone closes (with every column after it); the active
    // column falls back to its parent column.
    func testRelocatingAChildColumnClosesItAndDeeperColumns() async {
        let chain = ColumnChain(root: sandbox.root, makeModel: factory())
        await settle(chain)
        chain.models[0].select(.names(["A"]))
        await settle(chain)
        chain.models[1].select(.names(["B"]))
        await settle(chain)
        XCTAssertTrue(chain.moveRight())
        XCTAssertTrue(chain.moveRight())
        XCTAssertEqual(chain.activeIndex, 2)
        chain.models[1].relocate(to: sandbox.root, reason: .movedOrDeleted(name: "A"))
        XCTAssertEqual(chain.models.count, 1)
        XCTAssertEqual(chain.activeIndex, 0)
    }
}
