// Tests/CoreTests/Search/SearchResultsModelTests.swift
import XCTest
@testable import Core
@testable import MacxFS
import MacxFixtures

@MainActor
final class ScriptedSearchEvents {
    var continuations: [Generation: AsyncStream<SearchEvent>.Continuation] = [:]
    var terminated: [Generation] = []
    lazy var factory: @MainActor (Generation) -> AsyncStream<SearchEvent> = { [unowned self] gen in
        let (stream, c) = AsyncStream.makeStream(of: SearchEvent.self)
        c.onTermination = { [weak self] _ in Task { @MainActor in self?.terminated.append(gen) } }
        self.continuations[gen] = c
        return stream
    }
}

@MainActor
final class SearchResultsModelTests: XCTestCase {
    var sandbox: Sandbox!
    var env: CoreEnvironment!
    let types = TypeRegistry.shared

    override func setUp() async throws {
        sandbox = try Sandbox()
        let s = sandbox!
        addTeardownBlock { s.destroy() }
        env = CoreEnvironment.sandboxed(root: sandbox.root)
    }

    var rootPath: String { let p = sandbox.root.path(percentEncoded: false); return p.hasSuffix("/") ? String(p.dropLast()) : p }

    func batch(_ parent: String, _ names: [String], dirs: Set<String> = [], gen: Generation) -> SearchEvent {
        var b = Batch(generation: gen)
        for name in names {
            let isDir = dirs.contains(name)
            let e = Entry(rowID: 1, fileID: 1, size: Int64(name.count), allocSize: 0, mtime: 0, ctime: 0, nameOffset: 0,
                          nameLen: UInt16(name.utf8.count), kind: isDir ? .directory : .file, flags: [],
                          typeIndex: isDir ? TypeRegistry.folderIndex
                              : types.index(forExtension: Substring((name as NSString).pathExtension), isDirectory: false))
            Array(name.utf8).withUnsafeBufferPointer { b.append(e, nameBytes: $0) }
        }
        return .batch(SearchBatch(parent: URL(filePath: rootPath + parent, directoryHint: .isDirectory), batch: b))
    }

    func names(_ m: SearchResultsModel) -> [String] { (0..<m.rowCount).map { m.name(atRow: $0) } }

    func waitUntil(_ what: String, timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { try? await Task.sleep(for: .milliseconds(5)) }
        let ok = condition()
        XCTAssertTrue(ok, "timed out: \(what)")
    }

    func makeModel(_ script: ScriptedSearchEvents) -> SearchResultsModel {
        let m = SearchResultsModel(title: "test", events: script.factory, context: env.searchContext())
        addTeardownBlock { @MainActor in m.close() }
        return m
    }

    func testStreamsSortsFoldersFirstAndCompletes() async {
        let script = ScriptedSearchEvents()
        let m = makeModel(script)
        m.start()
        let gen = m.generation
        script.continuations[gen]!.yield(batch("/b", ["zeta.txt", "Alpha.txt"], gen: gen))
        script.continuations[gen]!.yield(batch("/a", ["middle.txt", "Folder"], dirs: ["Folder"], gen: gen))
        script.continuations[gen]!.yield(.completed(SearchSummary(resultCount: 4, directoriesScanned: 3)))
        await waitUntil("complete") { if case .complete = m.state { true } else { false } }
        XCTAssertEqual(names(m), ["Folder", "Alpha.txt", "middle.txt", "zeta.txt"])
        XCTAssertEqual(m.parentURL(atRow: 2).lastPathComponent, "a")
        XCTAssertTrue(m.showsPathColumn)
        if case .complete(let s) = m.state { XCTAssertEqual(s.resultCount, 4) }
    }

    func testPathSort() async {
        let script = ScriptedSearchEvents()
        let m = makeModel(script)
        m.start()
        let gen = m.generation
        script.continuations[gen]!.yield(batch("/b", ["a.txt"], gen: gen))
        script.continuations[gen]!.yield(batch("/a", ["z.txt", "b.txt"], gen: gen))
        await waitUntil("rows") { m.rowCount == 3 }
        m.setSortDescriptor(SortDescriptor(field: .path, ascending: true))
        await waitUntil("path order") { (0..<3).map { m.url(atRow: $0).path(percentEncoded: false) }.map { String($0.suffix(7)) } == ["a/b.txt", "a/z.txt", "b/a.txt"] }
        m.setSortDescriptor(SortDescriptor(field: .path, ascending: false))
        await waitUntil("descending") { m.name(atRow: 0) == "a.txt" }
    }

    // Review Focus 5
    func testRestartDropsStaleGenerationBatches() async {
        let script = ScriptedSearchEvents()
        let m = makeModel(script)
        m.start()
        let old = m.generation
        script.continuations[old]!.yield(batch("/", ["old-1.txt"], gen: old))
        await waitUntil("first rows") { m.rowCount == 1 }
        m.rerun()
        let new = m.generation
        XCTAssertGreaterThan(new, old)
        script.continuations[old]!.yield(batch("/", ["old-late.txt"], gen: old))       // late batch from the old engine
        script.continuations[new]!.yield(batch("/", ["stamped-old.txt"], gen: old))    // wrong generation on the new stream
        script.continuations[new]!.yield(batch("/", ["new.txt"], gen: new))
        await waitUntil("new rows") { m.rowCount >= 1 && m.name(atRow: 0) == "new.txt" }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(names(m), ["new.txt"])
        await waitUntil("old engine stopped") { script.terminated.contains(old) }
    }

    /// A completion (and batches) the old engine queued before start() is called again must not finish the new run.
    func testRestartDropsQueuedCompletionOfThePreviousRun() async {
        let script = ScriptedSearchEvents()
        let pacer = ManualFramePacer()
        var context = env.searchContext()
        context.pacer = pacer
        let m = SearchResultsModel(title: "test", events: script.factory, context: context)
        addTeardownBlock { @MainActor in m.close() }
        m.start()
        let old = m.generation
        script.continuations[old]!.yield(batch("/", ["old.txt"], gen: old))
        await waitUntil("pump waiting") { pacer.waiting == 1 }
        script.continuations[old]!.yield(.completed(SearchSummary(resultCount: 1)))
        try? await Task.sleep(for: .milliseconds(50))         // the old engine's completion is queued, no frame yet
        m.start()
        let new = m.generation
        pacer.tick()
        try? await Task.sleep(for: .milliseconds(50))         // the pump ran its frame (and idles: nothing left)
        guard case .searching = m.state else { return XCTFail("restarted run completed early: \(m.state)") }
        XCTAssertEqual(names(m), [])
        script.continuations[new]!.yield(batch("/", ["new.txt"], gen: new))
        script.continuations[new]!.yield(.completed(SearchSummary(resultCount: 1)))
        for _ in 0..<20 where { if case .complete = m.state { false } else { true } }() {
            pacer.tick(); try? await Task.sleep(for: .milliseconds(10))
        }
        await waitUntil("new run complete") { if case .complete = m.state { true } else { false } }
        XCTAssertEqual(names(m), ["new.txt"])
    }

    // Review Focus 5
    func testCloseStopsEngineAndEmitsNothing() async {
        let script = ScriptedSearchEvents()
        let m = makeModel(script)
        var events = 0
        let token = m.observe { _ in events += 1 }
        defer { token.cancel() }
        m.start()
        let gen = m.generation
        script.continuations[gen]!.yield(batch("/", ["a.txt"], gen: gen))
        await waitUntil("row") { m.rowCount == 1 }
        m.close()
        let before = events
        script.continuations[gen]!.yield(batch("/", ["b.txt"], gen: gen))
        script.continuations[gen]!.yield(.completed(SearchSummary()))
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(events, before)
        XCTAssertEqual(names(m), ["a.txt"])
        await waitUntil("engine terminated") { script.terminated.contains(gen) }
    }

    /// A model released without close() still cancels its engine (a live Spotlight query can stay silent forever).
    func testReleasingTheModelWithoutCloseTerminatesTheEngine() async {
        let script = ScriptedSearchEvents()
        var gen = Generation.initial
        do {
            let m = SearchResultsModel(title: "test", events: script.factory, context: env.searchContext())
            m.start()
            gen = m.generation
        }
        await waitUntil("engine terminated on release") { script.terminated.contains(gen) }
    }

    /// Identical states are not re-emitted while open.
    func testIdenticalStateIsNotReemitted() async {
        let script = ScriptedSearchEvents()
        let m = makeModel(script)
        var states: [SearchState] = []
        let token = m.observe { if case .state(let s) = $0 { states.append(s) } }
        defer { token.cancel() }
        m.start()
        let gen = m.generation
        let progress = SearchEvent.progress(SearchProgress(resultCount: 0))
        for _ in 0..<3 { script.continuations[gen]!.yield(progress) }
        script.continuations[gen]!.yield(.completed(SearchSummary()))
        await waitUntil("complete") { if case .complete = m.state { true } else { false } }
        for (a, b) in zip(states, states.dropFirst()) { XCTAssertNotEqual(a, b, "\(states)") }
    }

    // Review Focus 3
    func testLocalChangesRemoveAndRenameResults() async throws {
        let script = ScriptedSearchEvents()
        let m = makeModel(script)
        m.start()
        let gen = m.generation
        script.continuations[gen]!.yield(batch("/dir", ["a.txt", "b.txt", "sub"], dirs: ["sub"], gen: gen))
        script.continuations[gen]!.yield(batch("/dir/sub", ["c.txt"], gen: gen))
        script.continuations[gen]!.yield(.completed(SearchSummary(resultCount: 4)))
        await waitUntil("rows") { m.rowCount == 4 }
        let dir = URL(filePath: rootPath + "/dir", directoryHint: .isDirectory)
        env.changeBus.post([LocalChange(directory: dir, removed: ["a.txt"], renamed: [LocalChange.Rename(from: "b.txt", to: "z.txt")])])
        await waitUntil("trash + rename applied") { Set(self.names(m)) == ["sub", "c.txt", "z.txt"] }
        let z = try XCTUnwrap((0..<m.rowCount).first { m.name(atRow: $0) == "z.txt" })
        XCTAssertEqual(m.url(atRow: z).path(percentEncoded: false), rootPath + "/dir/z.txt")
        env.changeBus.post([LocalChange(directory: dir, removed: ["sub"])])           // folder trashed: its results go too
        await waitUntil("folder removal") { self.names(m) == ["z.txt"] }
        if case .complete = m.state {} else { XCTFail("state stays complete: \(m.state)") }
    }

    // Review Focus 3: a renamed folder's results are dropped (stale paths); a renamed selected item stays selected;
    // added names never join; the change bus may use the other "/private" spelling.
    func testRenamedFolderDropsItsResultsAndRenamedSelectionFollows() async throws {
        let script = ScriptedSearchEvents()
        let m = makeModel(script)
        m.start()
        let gen = m.generation
        script.continuations[gen]!.yield(batch("/dir", ["a.txt", "sub"], dirs: ["sub"], gen: gen))
        script.continuations[gen]!.yield(batch("/dir/sub/deeper", ["c.txt"], gen: gen))
        await waitUntil("rows") { m.rowCount == 3 }
        let a = try XCTUnwrap((0..<m.rowCount).first { m.name(atRow: $0) == "a.txt" })
        m.select(.set([a], cursor: a))
        let other = rootPath.hasPrefix("/private/") ? String(rootPath.dropFirst("/private".count)) : "/private" + rootPath
        let dir = URL(filePath: other + "/dir", directoryHint: .isDirectory)
        env.changeBus.post([LocalChange(directory: dir, added: ["new.txt"],
                                        renamed: [LocalChange.Rename(from: "sub", to: "sub2"), LocalChange.Rename(from: "a.txt", to: "b.txt")])])
        await waitUntil("renames applied") { Set(self.names(m)) == ["sub2", "b.txt"] }
        XCTAssertEqual(m.selectedURLs.map(\.lastPathComponent), ["b.txt"])
        XCTAssertEqual(m.selectionSummary.count, 1)
    }

    /// Search QA: undoing the trash of a result (or of a folder holding results) puts its rows back; a plain added
    /// name with the same path does not (contract note 12).
    func testRestoredItemsRejoinTheResults() async throws {
        let script = ScriptedSearchEvents()
        let m = makeModel(script)
        m.start()
        let gen = m.generation
        script.continuations[gen]!.yield(batch("/dir", ["a.txt", "b.txt", "sub"], dirs: ["sub"], gen: gen))
        script.continuations[gen]!.yield(batch("/dir/sub/deeper", ["c.txt"], gen: gen))
        script.continuations[gen]!.yield(.completed(SearchSummary(resultCount: 4)))
        await waitUntil("rows") { m.rowCount == 4 }
        let dir = URL(filePath: rootPath + "/dir", directoryHint: .isDirectory)
        env.changeBus.post([LocalChange(directory: dir, removed: ["a.txt", "sub"])])
        await waitUntil("trashed") { self.names(m) == ["b.txt"] }
        env.changeBus.post([LocalChange(directory: dir, added: ["a.txt"])])             // a new file, not a put back
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(names(m), ["b.txt"])
        env.changeBus.post([LocalChange(directory: dir, added: ["a.txt", "sub"], restored: ["a.txt", "sub"])])
        await waitUntil("put back") { Set(self.names(m)) == ["a.txt", "b.txt", "sub", "c.txt"] }
        let c = try XCTUnwrap((0..<m.rowCount).first { m.name(atRow: $0) == "c.txt" })
        XCTAssertEqual(m.url(atRow: c).path(percentEncoded: false), rootPath + "/dir/sub/deeper/c.txt")
        if case .complete = m.state {} else { XCTFail("state stays complete: \(m.state)") }
        // Restored once: a later put back of the same name (nothing set aside any more) adds nothing.
        env.changeBus.post([LocalChange(directory: dir, removed: ["b.txt"])])
        await waitUntil("trashed again") { m.rowCount == 3 }
        m.rerun()                                                                       // a re-run forgets what was set aside
        env.changeBus.post([LocalChange(directory: dir, added: ["b.txt"], restored: ["b.txt"])])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(names(m).contains("b.txt"))
    }

    func testSelectionFollowsIdentityAcrossBatches() async {
        let script = ScriptedSearchEvents()
        let m = makeModel(script)
        m.start()
        let gen = m.generation
        script.continuations[gen]!.yield(batch("/", ["m.txt", "z.txt"], gen: gen))
        await waitUntil("rows") { m.rowCount == 2 }
        m.select(.set([1], cursor: 1))
        XCTAssertEqual(m.selectedURLs.map(\.lastPathComponent), ["z.txt"])
        script.continuations[gen]!.yield(batch("/", ["a.txt"], gen: gen))
        await waitUntil("merged") { m.rowCount == 3 }
        XCTAssertEqual(m.selection.rows, [2])
        XCTAssertEqual(m.selectedURLs.map(\.lastPathComponent), ["z.txt"])
        XCTAssertEqual(m.selectionSummary.count, 1)
    }

    func testStopKeepsResultsAndCutDims() async {
        let script = ScriptedSearchEvents()
        let m = makeModel(script)
        m.start()
        let gen = m.generation
        script.continuations[gen]!.yield(batch("/", ["a.txt"], gen: gen))
        await waitUntil("row") { m.rowCount == 1 }
        m.stop()
        if case .stopped(let s) = m.state { XCTAssertEqual(s.resultCount, 1) } else { XCTFail("\(m.state)") }
        await waitUntil("engine stopped") { script.terminated.contains(gen) }
        m.cutURLs = [m.url(atRow: 0)]
        XCTAssertTrue(m.isCut(row: 0))
    }

    func testResultLimitStopsAndNotifies() async {
        let script = ScriptedSearchEvents()
        let m = makeModel(script)
        m.start()
        let gen = m.generation
        let names = (0...SearchResultsModel.resultLimit).map { "f\($0)" }
        script.continuations[gen]!.yield(batch("/", names, gen: gen))
        await waitUntil("capped", timeout: 20) { if case .complete = m.state { true } else { false } }
        XCTAssertEqual(m.rowCount, SearchResultsModel.resultLimit)
        XCTAssertTrue(m.notices.contains(.truncated(limit: SearchResultsModel.resultLimit)))
        if case .complete(let s) = m.state { XCTAssertTrue(s.truncated) }
        await waitUntil("engine stopped") { script.terminated.contains(gen) }
    }

    func testSpecModelCrawlsTheSandbox() async throws {
        try sandbox.createFile("work/tax-2025.pdf")
        try sandbox.createFile("work/deep/er/tax-old.pdf")
        try sandbox.createFile("work/notes.txt")
        let spec = SearchSpec(text: "tax", scope: .subfolders, root: sandbox.url("work"))
        let plan = await env.planSearch(spec)
        // The root keeps the caller's spelling (lexical cleanup only, no stat on main: contract note 15).
        let work = URL(filePath: rootPath + "/work", directoryHint: .isDirectory)
        XCTAssertEqual(plan.engine, .crawler(root: work, criteria: SearchCriteria(nameTerms: [NameTerm("tax")])))
        let m = env.makeSearchResults(spec, plan: plan)
        addTeardownBlock { @MainActor in m.close() }
        m.start()
        await waitUntil("crawl complete") { if case .complete = m.state { true } else { false } }
        XCTAssertEqual(names(m), ["tax-2025.pdf", "tax-old.pdf"])
        XCTAssertEqual(m.title, "tax")
    }

    func testMayNotBeIndexedNoticeForEmptyFolderScopedSpotlight() async throws {
        var context = env.searchContext()
        context.services = .fake(items: [], indexing: .enabled)
        let spec = SearchSpec(text: "invoice", scope: .subfolders, mode: .contents, root: sandbox.root)
        let plan = await context.plan(spec)
        guard case .spotlight = plan.engine else { return XCTFail("\(plan.engine)") }
        let m = SearchResultsModel(spec: spec, plan: plan, context: context)
        addTeardownBlock { @MainActor in m.close() }
        m.start()
        await waitUntil("complete") { if case .complete = m.state { true } else { false } }
        XCTAssertEqual(m.notices, [.mayNotBeIndexed])
    }

    /// AppBootstrap's choice: any sandboxed, rooted or scenario launch gets the fakes (never real Spotlight or iCloud).
    func testSandboxedLaunchOptionsUseFakeSearchServices() throws {
        let lanes = LanePool()
        for args in [["--root", "/tmp/macx-x", "--state-dir", "/tmp/macx-x/state"],
                     ["--state-dir", "/tmp/macx-x/state"]] {
            let services = SearchServices.forLaunch(try LaunchOptions.parse(["macExplorer"] + args), lanes: lanes)
            XCTAssertTrue(services.metadataQuery is FakeMetadataQuery, "\(args)")
            XCTAssertTrue(services.downloader is FakeUbiquitousDownloader, "\(args)")
            XCTAssertTrue(services.indexStatus is FixedIndexStatus, "\(args)")
        }
        let live = SearchServices.forLaunch(try LaunchOptions.parse(["macExplorer"]), lanes: lanes)
        XCTAssertTrue(live.metadataQuery is SystemMetadataQuery)        // constructing it starts no query
    }

    func testSandboxedEnvironmentUsesFakeSearchServices() {
        XCTAssertTrue(env.searchServices.metadataQuery is FakeMetadataQuery)
        XCTAssertTrue(env.searchServices.downloader is FakeUbiquitousDownloader)
    }
}
