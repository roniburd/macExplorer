import Foundation
import MacxFS

public enum SearchState: Sendable, Equatable {
    case searching(SearchProgress), complete(SearchSummary), stopped(SearchSummary), failed(SearchFailure)
}
public enum SearchModelEvent: Sendable { case rows(RowSourceEvent), state(SearchState), notices([SearchNotice]) }

/// Streaming results of one crawler or Spotlight search (§11 Phase 3), shown by the Details/Icons views through
/// RowSource. Rows are applied by one pump at most once per frame; batches of an older generation are dropped
/// (Review Focus 5); local trashes, moves and renames update the rows without re-running (Review Focus 3).
/// The model never touches the file system.
@MainActor
public final class SearchResultsModel: RowSource {
    public static let resultLimit = 100_000

    public let title: String
    public let spec: SearchSpec?
    public let plan: SearchPlan?
    public private(set) var state: SearchState = .searching(SearchProgress())
    public private(set) var notices: [SearchNotice]
    public private(set) var generation: Generation = .initial
    public private(set) var results = SearchResultStore()
    public private(set) var selection: Selection = .empty
    public private(set) var sortDescriptor: MacxFS.SortDescriptor = .default
    public var scrollAnchor: RowID?
    public var cutURLs: Set<URL> = [] {
        didSet { if cutURLs != oldValue, rowCount > 0 { emitRows(.changes(ChangeSet([.reload(IndexSet(integersIn: 0..<rowCount))]))) } }
    }

    /// `.complete` sits in the queue behind the batches that preceded it, so completion is applied after them
    /// (and not after later local changes).
    private enum Op { case batch(SearchBatch), removed([String]), local(LocalChange), complete(SearchSummary) }

    private let context: SearchContext
    private let makeEvents: @MainActor (Generation) -> AsyncStream<SearchEvent>
    private let baseNotices: [SearchNotice]
    private var engineTask: Task<Void, Never>?
    private var pending: [Op] = []
    private var needsFullSort = false
    private var pumping = false
    private var pendingCompletion: SearchSummary?        // applied at the end of the pump round that reached it
    private var closed = false
    private var startedAt = ContinuousClock.now
    private var directoriesScanned = 0
    private var parentKeys = SortKeyColumn()             // ResultSorter.parentKey per results.parents entry
    private let rowObservers = Observers<RowSourceEvent>()
    private let observers = Observers<SearchModelEvent>()
    private var changeToken: ObserverToken?

    public init(spec: SearchSpec, plan: SearchPlan, context: SearchContext) {
        switch plan.engine {
        case .crawler, .spotlight: break
        case .none, .folderFilter: preconditionFailure("SearchResultsModel needs a crawler or Spotlight plan")
        }
        title = spec.text.trimmingCharacters(in: .whitespaces)
        self.spec = spec
        self.plan = plan
        self.context = context
        notices = plan.notices
        baseNotices = plan.notices
        let engine = plan.engine
        makeEvents = { gen in SearchResultsModel.engineEvents(engine, generation: gen, context: context) }
        observeLocalChanges()
    }

    /// Externally built stream (Phase 4 TAGS); `events` is called once per start/rerun with the new generation.
    public init(title: String, events: @escaping @MainActor (Generation) -> AsyncStream<SearchEvent>, context: SearchContext) {
        self.title = title
        spec = nil
        plan = nil
        self.context = context
        notices = []
        baseNotices = []
        makeEvents = events
        observeLocalChanges()
    }

    static func engineEvents(_ engine: SearchEngine, generation: Generation, context: SearchContext) -> AsyncStream<SearchEvent> {
        switch engine {
        case .crawler(let root, let criteria):
            var options = CrawlOptions()
            options.includeHidden = context.settings.showHidden
            options.includePackages = context.settings.searchIncludesPackages
            options.showAllExtensions = context.settings.showAllExtensions
            options.maxResults = resultLimit
            return SubtreeCrawler.crawl(root: root, criteria: criteria, options: options, permissions: context.crawlPermissions(),
                                        generation: generation, lanes: context.lanes, mountTable: context.volumes.mountTableStore,
                                        types: context.types)
        case .spotlight(let request):
            return SpotlightSearch.events(request, query: context.services.metadataQuery, includeHidden: context.settings.showHidden,
                                          generation: generation, types: context.types)
        case .none, .folderFilter:
            preconditionFailure("not a streaming engine")
        }
    }

    // MARK: lifecycle

    /// Starts (or restarts) the engine with a new generation.
    public func start() {
        guard !closed else { return }
        engineTask?.cancel()
        generation = generation.next()
        let gen = generation
        startedAt = .now
        directoriesScanned = 0
        pendingCompletion = nil
        setState(.searching(SearchProgress(resultCount: results.count)))
        let stream = makeEvents(gen)
        engineTask = Task { [weak self] in
            for await event in stream {
                guard let self, !self.closed, self.generation == gen else { return }
                self.handle(event, generation: gen)
            }
        }
    }

    /// Cancels the engine; rows already received stay.
    public func stop() {
        guard case .searching = state, !closed else { return }
        engineTask?.cancel()
        engineTask = nil
        pendingCompletion = nil
        setState(.stopped(SearchSummary(resultCount: results.count + pendingResultCount, directoriesScanned: directoriesScanned,
                                        elapsed: .now - startedAt)))
    }

    /// Clears rows, selection and notices (back to the plan's) and starts again with a new generation.
    public func rerun() {
        guard !closed else { return }
        engineTask?.cancel()
        engineTask = nil
        pending = []
        pendingCompletion = nil
        needsFullSort = false
        results = SearchResultStore()
        parentKeys = SortKeyColumn()
        selection = .empty
        scrollAnchor = nil
        notices = baseNotices
        emit(.notices(notices))
        emitRows(.changes(.reset))
        emitRows(.selection(selection))
        start()
    }

    /// Cancels the engine and the change-bus observer; emits nothing afterwards.
    public func close() {
        guard !closed else { return }
        closed = true
        engineTask?.cancel()
        engineTask = nil
        changeToken?.cancel()
        changeToken = nil
        pending = []
        pendingCompletion = nil
    }

    public func observe(_ handler: @escaping @MainActor (SearchModelEvent) -> Void) -> ObserverToken { observers.add(handler) }

    // MARK: engine events

    private func handle(_ event: SearchEvent, generation gen: Generation) {
        if case .stopped = state { return }
        switch event {
        case .batch(let b):
            guard b.batch.generation == gen else { return }
            enqueue(.batch(b))
        case .removed(let paths):
            enqueue(.removed(paths))
        case .progress(let p):
            directoriesScanned = p.directoriesScanned
            if case .searching = state {
                setState(.searching(SearchProgress(directoriesScanned: p.directoriesScanned,
                                                   resultCount: results.count + pendingResultCount, currentPath: p.currentPath)))
            }
        case .notice(let n):
            addNotice(n)
        case .completed(let summary):
            guard case .searching = state else { return }
            enqueue(.complete(summary))
        case .failed(let failure):
            guard case .searching = state else { return }
            pendingCompletion = nil
            setState(.failed(failure))
        }
    }

    private var pendingResultCount: Int {
        pending.reduce(0) { if case .batch(let b) = $1 { $0 + b.batch.count } else { $0 } }
    }

    private func finish(_ summary: SearchSummary) {
        guard case .searching = state else { return }
        var s = summary
        s.resultCount = results.count
        if s.directoriesScanned == 0 { s.directoriesScanned = directoriesScanned }
        if s.elapsed == .zero { s.elapsed = .now - startedAt }
        if s.truncated { addNotice(.truncated(limit: Self.resultLimit)) }
        if s.skippedTotal > 0 { addNotice(.skippedLocations(count: s.skippedTotal)) }
        if results.count == 0, case .spotlight(let request)? = plan?.engine, case .folders = request.scope { addNotice(.mayNotBeIndexed) }
        setState(.complete(s))
    }

    /// The model's own cap (the engines cap too): stop the engine and complete as truncated.
    private func hitLimit() {
        engineTask?.cancel()
        engineTask = nil
        if case .searching = state {
            pendingCompletion = SearchSummary(resultCount: results.count, directoriesScanned: directoriesScanned, truncated: true)
        }
    }

    // MARK: local changes (Review Focus 3)

    private func observeLocalChanges() {
        changeToken = context.changeBus.observeAll { [weak self] change in self?.receive(change) }
    }

    private func receive(_ change: LocalChange) {
        guard !closed, !change.removed.isEmpty || !change.renamed.isEmpty, results.count > 0 || !pending.isEmpty else { return }
        enqueue(.local(change))
    }

    /// Removed names drop their row and every result below them (folder trashed or moved). Renamed items are
    /// re-keyed and re-sorted; results below a renamed folder are dropped (their paths are stale). Added and
    /// modified names never join the results (contract note 12).
    private func applyLocal(_ change: LocalChange) {
        let dir = SearchResultStore.standardizedParent(change.directory)
        var exact: [String] = []
        var under: [String] = []
        for name in change.removed {
            let p = SearchResultStore.join(dir, name)
            if results.index(ofPath: p) != nil { exact.append(p) }
            under.append(p)
        }
        for rename in change.renamed { under.append(SearchResultStore.join(dir, rename.from)) }
        if !exact.isEmpty { results.remove(paths: exact) }
        removeResults(under: under)
        for rename in change.renamed {
            let from = SearchResultStore.join(dir, rename.from)
            guard let old = results.index(ofPath: from) else { continue }
            let oldID = results.identity(old)
            let target = SearchResultStore.join(dir, rename.to)
            guard results.rename(path: from, to: rename.to, types: context.types), let i = results.index(ofPath: target) else { continue }
            selection.substitute(oldID, with: results.identity(i))
            if scrollAnchor == oldID { scrollAnchor = results.identity(i) }
            mergeIntoOrder([i])
        }
    }

    /// Drops every result whose parent is one of `folders` or below one (lexical keys, any /private spelling).
    private func removeResults(under folders: [String]) {
        guard !folders.isEmpty else { return }
        let keys = folders.map(SearchResultStore.key)
        var stale = Set<UInt32>()
        for (i, parent) in results.parents.enumerated() {
            let k = SearchResultStore.key(parent)
            if keys.contains(where: { k == $0 || k.hasPrefix($0 == "/" ? "/" : $0 + "/") }) { stale.insert(UInt32(i)) }
        }
        guard !stale.isEmpty else { return }
        let paths = (0..<UInt32(results.count)).filter { stale.contains(results.parentIndex($0)) }.map { results.path($0) }
        results.remove(paths: paths)
    }

    // MARK: pump

    private func enqueue(_ op: Op) {
        pending.append(op)
        schedulePump()
    }

    private func schedulePump() {
        guard !pumping, !closed else { return }
        pumping = true
        Task { [weak self] in await self?.pump() }
    }

    private func pump() async {
        while !closed {
            await context.pacer.nextFrame()
            if closed { break }
            if pending.isEmpty && !needsFullSort {
                if let s = pendingCompletion { pendingCompletion = nil; finish(s) }
                break
            }
            let gen = generation
            let before = selection
            let ops = pending
            pending = []
            applyOps(ops)
            if needsFullSort {
                needsFullSort = false
                let sort = sortDescriptor
                parentKeys = ResultSorter.parentKeys(results, extending: parentKeys)
                let order = await ResultSorter.permutationOffMain(results, sort: sort, kindRanks: context.types.kindRanks().ranks,
                                                                   parentKeys: parentKeys)
                if closed { break }
                if gen != generation { continue }
                if sort != sortDescriptor { needsFullSort = true; continue }
                results.setOrder(order)
            }
            selection.reconcile(in: rowSpace())
            if let anchor = scrollAnchor, row(of: anchor) == nil { scrollAnchor = nil }
            emitRows(.changes(.reset))
            if selection != before { emitRows(.selection(selection)) }
            if let s = pendingCompletion {
                pendingCompletion = nil
                finish(s)
            } else if case .searching(var p) = state {
                p.resultCount = results.count
                setState(.searching(p))
            }
        }
        pumping = false
    }

    /// Merges new storage indices into the displayed order (skipped while a full sort is due: it covers them).
    private func mergeIntoOrder(_ fresh: [UInt32]) {
        guard !fresh.isEmpty, !needsFullSort else { return }
        parentKeys = ResultSorter.parentKeys(results, extending: parentKeys)
        results.setOrder(ResultSorter.merge(results.store.order, fresh, results: results, sort: sortDescriptor,
                                            kindRanks: context.types.kindRanks().ranks, parentKeys: parentKeys))
    }

    private func applyOps(_ ops: [Op]) {
        var fresh: [UInt32] = []
        func flushFresh() {
            mergeIntoOrder(fresh)
            fresh = []
        }
        for op in ops {
            switch op {
            case .batch(var b):
                let room = Self.resultLimit - results.count          // `fresh` rows are already in `results`
                if room <= 0 { hitLimit(); continue }
                if b.batch.count > room { b.batch = CrawlRun.prefix(b.batch, room) }
                let parent = SearchResultStore.standardizedParent(b.parent)
                let replaces = (0..<b.batch.count).contains { results.index(ofPath: SearchResultStore.join(parent, b.batch.name(at: $0))) != nil }
                if replaces { flushFresh() }                          // append compacts storage: merge pending indices first
                fresh += results.append(b)
                if results.count >= Self.resultLimit { hitLimit() }
            case .removed(let paths):
                flushFresh()
                results.remove(paths: paths)
            case .local(let change):
                flushFresh()
                applyLocal(change)
            case .complete(let summary):
                if pendingCompletion == nil { pendingCompletion = summary }   // a model-side cap (hitLimit) wins
            }
        }
        flushFresh()
    }

    // MARK: RowSource

    public var rowCount: Int { results.store.visibleCount }
    private func index(_ row: Int) -> UInt32 { results.store.storageIndex(forRow: row) }
    public func entry(atRow row: Int) -> Entry { results.store.entry(index(row)) }
    public func name(atRow row: Int) -> String { results.store.name(index(row)) }
    public func displayName(atRow row: Int) -> String {
        results.displayName(index(row), showAllExtensions: context.settings.showAllExtensions)
    }
    public func url(atRow row: Int) -> URL { results.url(index(row)) }
    public func parentURL(atRow row: Int) -> URL { URL(filePath: results.parentPath(index(row)), directoryHint: .isDirectory) }
    public func identity(atRow row: Int) -> RowID { results.identity(index(row)) }
    public func row(of id: RowID) -> Int? {
        guard case .name(let path) = id, let i = results.index(ofPath: path) else { return nil }
        return results.store.row(ofStorageIndex: i)
    }

    private func rowSpace() -> SelectionRowSpace {
        SelectionRowSpace(count: rowCount, identity: { [unowned self] in identity(atRow: $0) },
                          row: { [unowned self] in row(of: $0) },
                          rowsNamed: { [unowned self] names in
                              let wanted = Set(names)
                              return IndexSet((0..<rowCount).filter { wanted.contains(name(atRow: $0)) })
                          })
    }

    public func select(_ command: SelectionCommand) {
        let before = selection
        selection.apply(command, in: rowSpace())
        if selection != before { emitRows(.selection(selection)) }
    }
    public var selectedURLs: [URL] { selection.rows.map { url(atRow: $0) } }
    public var selectionSummary: SelectionSummary {
        var files = 0, folders = 0
        var bytes: Int64 = 0
        for row in selection.rows {
            let e = entry(atRow: row)
            switch e.kind {
            case .directory: folders += 1
            case .package: files += 1                          // a package's size is its entry count (FolderModel rule)
            default: files += 1; bytes += e.size
            }
        }
        return SelectionSummary(count: selection.count, files: files, folders: folders, bytes: bytes)
    }
    public func isCut(row: Int) -> Bool { !cutURLs.isEmpty && cutURLs.contains(url(atRow: row)) }
    public func setSortDescriptor(_ sort: MacxFS.SortDescriptor) {
        guard sort != sortDescriptor else { return }
        sortDescriptor = sort
        needsFullSort = true
        schedulePump()
    }
    public var showsPathColumn: Bool { true }
    public var caseSensitive: Bool { spec.flatMap { context.volumes.volume(for: $0.root) }?.capabilities.caseSensitive ?? false }

    /// Checks only listed siblings; unlisted ones are caught by the rename job's RENAME_EXCL (EEXIST dialog).
    public func validateName(_ proposed: String, renamingRow row: Int?) -> NameValidation {
        let parent = row.map { results.parentPath(index($0)) }
        let isFolder = row.map { entry(atRow: $0).kind == .directory } ?? false
        let result = NameRules.validate(proposed, original: row.map { name(atRow: $0) }, caseSensitive: caseSensitive) { candidate in
            guard let parent else { return false }
            return self.results.index(ofPath: SearchResultStore.join(parent, candidate)) != nil
        }
        guard isFolder, case .ok(let warnings) = result else { return result }
        return .ok(warnings: warnings.filter { if case .extensionChanged = $0 { false } else { true } })
    }
    public func observeRows(_ handler: @escaping @MainActor (RowSourceEvent) -> Void) -> ObserverToken { rowObservers.add(handler) }

    // MARK: emit

    private func setState(_ s: SearchState) {
        guard s != state || closed == false else { return }
        state = s
        emit(.state(s))
    }
    private func addNotice(_ n: SearchNotice) {
        guard !notices.contains(n) else { return }
        notices.append(n)
        emit(.notices(notices))
    }
    private func emit(_ e: SearchModelEvent) { if !closed { observers.send(e) } }
    private func emitRows(_ e: RowSourceEvent) {
        guard !closed else { return }
        rowObservers.send(e)
        observers.send(.rows(e))
    }
}
