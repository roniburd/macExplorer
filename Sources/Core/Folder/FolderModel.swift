import CoreServices
import Foundation
import MacxFS

public enum RelocationReason: Sendable, Equatable { case movedOrDeleted(name: String), volumeGone }

public enum FolderEvent: Sendable {
    case changes(ChangeSet)
    case state(FolderState)
    case selection(Selection)
    case beginRename(row: Int)
    case relocate(to: URL, reason: RelocationReason)   // window navigates; banner for .movedOrDeleted
    case query(ViewQuery)
}

/// Services a FolderModel uses (CoreEnvironment.folderContext() builds the real one).
@MainActor
public struct FolderContext {
    public var readers: DirectoryReaders
    public var lanes: LanePool
    public var volumes: Volumes
    public var changeBus: ChangeBus
    public var types: TypeRegistry
    public var pacer: any FramePacer
    public var makeWatcher: @MainActor (URL, UInt64, @escaping @Sendable (WatchEvent) -> Void) -> any ContentWatching
    public var permissionPending: @MainActor (URL) -> Bool     // Settings TCC outcome lookup
    public var recordPermissionOutcome: @MainActor (URL, Bool) -> Void   // granted true / EPERM false
    /// Where a model relocates when its volume goes away (Settings.home: the sandbox root in sandbox mode).
    public var home: URL

    public init(readers: DirectoryReaders, lanes: LanePool, volumes: Volumes, changeBus: ChangeBus,
                types: TypeRegistry = .shared, pacer: any FramePacer = TimerFramePacer(),
                makeWatcher: @escaping @MainActor (URL, UInt64, @escaping @Sendable (WatchEvent) -> Void) -> any ContentWatching,
                permissionPending: @escaping @MainActor (URL) -> Bool,
                recordPermissionOutcome: @escaping @MainActor (URL, Bool) -> Void,
                home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
        self.readers = readers
        self.lanes = lanes
        self.volumes = volumes
        self.changeBus = changeBus
        self.types = types
        self.pacer = pacer
        self.makeWatcher = makeWatcher
        self.permissionPending = permissionPending
        self.recordPermissionOutcome = recordPermissionOutcome
    }
}

/// The snapshot one folder view observes (§4.3): the only owner and mutator of its EntryStore, the state machine,
/// the selection by identity and the query. Sorting and diffing run in `FolderWorker`; reads run on lanes.
@MainActor
public final class FolderModel {
    /// Test seams (@testable): where listings and item stats come from.
    typealias ReadSource = @MainActor (URL, Generation, ReadOptions) async -> AsyncStream<ReadEvent>
    typealias ItemSource = @MainActor ([String], URL, Generation) async throws -> ItemReadResult

    public let directory: URL
    public private(set) var state: FolderState = .loading
    public private(set) var store: EntryStore
    public private(set) var query: ViewQuery
    public private(set) var selection: Selection = .empty
    public private(set) var generation: Generation = .initial

    public var scrollAnchor: RowID?            // views set on scroll; restored after resets
    public var cutNames: Set<String> = []      // from Clipboard; views dim these rows

    var readSource: ReadSource
    var itemSource: ItemSource

    let context: FolderContext
    let worker: FolderWorker
    let observers = Observers<FolderEvent>()

    // Lifecycle
    private(set) var started = false
    private(set) var closed = false
    private var startEventID: UInt64 = 0
    private(set) var watcher: (any ContentWatching)?
    private var busToken: ObserverToken?
    private var volumeToken: ObserverToken?
    /// The volume the folder was opened on; when it leaves the volume list the model relocates home.
    let openedVolume: VolumeID?

    // Watcher (FolderModel+Watch)
    var watchBuffer = WatchBuffer()
    var relocated = false

    // The read in progress
    private var readTask: Task<Void, Never>?
    private var pacerTask: Task<Void, Never>?
    private var permissionAsked = false
    private var rowsPresented = false
    /// Incremented by every fresh load (start, retry): store-mutating work captured under an older epoch is dropped.
    private(set) var epoch = 0
    /// Keys tag of `store` in the worker (FolderWorker.KeysTag).
    var keysTag: FolderWorker.KeysTag = 0

    // Serialized store mutations after the first listing (re-sorts, patches, re-read results)
    private var opTail: Task<Void, Never>?
    var rereadInFlight = false
    var rereadPending = false
    var namesPatchedDuringReread: Set<String> = []
    var deferredChanges: [LocalChange] = []
    var pendingSelect: [String] = []
    var pendingRename: String?

    public init(directory: URL, context: FolderContext, query: ViewQuery) {
        self.directory = directory
        self.context = context
        self.query = query
        let mode = context.volumes.volume(for: directory)?.capabilities.identityMode ?? .objectID
        self.store = EntryStore(identityMode: mode)
        self.openedVolume = context.volumes.volume(for: directory)?.id
        self.worker = FolderWorker(types: context.types)
        let readers = context.readers
        readSource = { directory, generation, options in
            await readers.reader(for: directory).read(directory, generation: generation, options: options)
        }
        itemSource = { names, directory, generation in
            try await readers.reader(for: directory).readItems(names, in: directory, generation: generation)
        }
    }

    public var volume: VolumeInfo? { context.volumes.volume(for: directory) }
    public var caseSensitive: Bool { volume?.capabilities.caseSensitive ?? false }

    // MARK: Lifecycle

    /// Capture the FSEvents ID, read, then watch (§4.3 no gap).
    public func start() {
        guard !started, !closed else { return }
        started = true
        busToken = context.changeBus.observe(directory: directory) { [weak self] change in self?.applyLocalChange(change) }
        volumeToken = context.volumes.observe { [weak self] list in self?.volumesChanged(list) }
        startEventID = FSEventsGetCurrentEventId()
        beginLoad()
    }

    /// F5/⌘R: re-read + diff, keeps rows, never → .loading. From an error or unresponsive state it retries.
    public func refresh() {
        guard started, !closed else { return }
        switch state {
        case .complete: beginReread()
        case .loading, .partial: break
        case .error, .unresponsive, .waitingForPermission: retry()
        }
    }

    /// From .error/.unresponsive: → .loading with a new generation; late results of the old one are discarded.
    public func retry() {
        guard started, !closed else { return }
        switch state {
        case .error, .unresponsive, .waitingForPermission: break
        default: return
        }
        clearRows()
        setState(.loading)
        beginLoad()
    }

    /// Cancels the read, stops the watcher, drops observers. Idempotent; a closed model emits nothing.
    public func close() {
        guard !closed else { return }
        closed = true
        readTask?.cancel()
        pacerTask?.cancel()
        opTail?.cancel()
        readTask = nil
        pacerTask = nil
        stopWatcher()
        busToken?.cancel()
        busToken = nil
        volumeToken?.cancel()
        volumeToken = nil
        let worker = self.worker
        Task { await worker.cancel() }
    }

    // MARK: Rows

    public var rowCount: Int { store.visibleCount }
    public func entry(atRow row: Int) -> Entry { store.entry(store.storageIndex(forRow: row)) }
    public func name(atRow row: Int) -> String { store.name(store.storageIndex(forRow: row)) }

    public func url(atRow row: Int) -> URL {
        let kind = entry(atRow: row).kind
        return directory.appending(path: name(atRow: row),
                                   directoryHint: kind == .directory || kind == .package ? .isDirectory : .notDirectory)
    }

    public func identity(atRow row: Int) -> RowID { store.identity(store.storageIndex(forRow: row)) }
    public func row(of id: RowID) -> Int? { store.row(of: id) }

    /// NameNormalizer.sameName semantics; nil when the item is hidden from the current view.
    public func row(named name: String) -> Int? {
        store.firstIndex(named: name, caseSensitive: caseSensitive).flatMap { store.row(ofStorageIndex: $0) }
    }

    public func errno(atRow row: Int) -> Int32? { store.errno(store.storageIndex(forRow: row)) }

    // MARK: Query

    /// Re-sort/filter off main; one .changes(.reset).
    public func setQuery(_ query: ViewQuery) {
        guard query != self.query else { return }
        self.query = query
        emit(.query(query))
        switch state {
        case .loading, .partial, .unresponsive, .waitingForPermission:
            let worker = self.worker
            Task { await worker.setLoadingQuery(query) }
        case .complete:
            enqueue { [weak self] in await self?.resortNow() }
        case .error:
            break
        }
    }

    private func resortNow() async {
        let snapshot = store, wanted = query, epoch = self.epoch
        let signpost = PerfSignposts.signposter.beginInterval(PerfSignposts.sort)
        let order = await worker.resort(snapshot, tag: keysTag, query: wanted)
        PerfSignposts.signposter.endInterval(PerfSignposts.sort, signpost)
        // A newer setQuery queued its own re-sort; a fresh load replaced the store.
        guard !closed, epoch == self.epoch, wanted == query, store.version == snapshot.version else { return }
        store.setOrder(order)
        publishReset()
    }

    // MARK: Selection

    public func select(_ command: SelectionCommand) {
        pendingSelect = []
        let before = selection
        selection.apply(command, in: rowSpace)
        if selection != before { emit(.selection(selection)) }
    }

    public var selectedURLs: [URL] { selection.rows.map { url(atRow: $0) } }

    public var selectionSummary: SelectionSummary {
        var files = 0, folders = 0
        var bytes: Int64 = 0
        for row in selection.rows {
            let e = entry(atRow: row)
            switch e.kind {
            case .directory: folders += 1
            case .package: files += 1                 // size is its entry count; bytes are folder sizes (Phase 2)
            default: files += 1; bytes += e.size
            }
        }
        return SelectionSummary(count: selection.count, files: files, folders: folders, bytes: bytes)
    }

    public func isCut(row: Int) -> Bool { !cutNames.isEmpty && cutNames.contains(name(atRow: row)) }

    var rowSpace: SelectionRowSpace {
        SelectionRowSpace(count: rowCount, identity: { [unowned self] in identity(atRow: $0) },
                          row: { [unowned self] in row(of: $0) }, rowNamed: { [unowned self] in row(named: $0) })
    }

    /// Recomputes selection rows after the order changed; sends .selection if it changed.
    func reconcileSelection(emitting: Bool = true) {
        let before = selection
        selection.reconcile(in: rowSpace)
        if let anchor = scrollAnchor, row(of: anchor) == nil { scrollAnchor = nil }
        if emitting && selection != before { emit(.selection(selection)) }
    }

    /// Moves identity-keyed state (selection, scroll anchor) from `old` to `new`.
    func substitute(_ old: RowID, with new: RowID) {
        guard old != new else { return }
        selection.substitute(old, with: new)
        if scrollAnchor == old { scrollAnchor = new }
    }

    // MARK: Names

    public func validateName(_ proposed: String, renamingRow row: Int?) -> NameValidation {
        let original = row.map { name(atRow: $0) }
        let isFolder = row.map { entry(atRow: $0).kind == .directory } ?? false
        let snapshot = store, caseSensitive = self.caseSensitive
        let result = NameRules.validate(proposed, original: original, caseSensitive: caseSensitive) { name in
            snapshot.firstIndex(named: name, caseSensitive: caseSensitive) != nil
        }
        guard isFolder, case .ok(let warnings) = result else { return result }
        return .ok(warnings: warnings.filter { if case .extensionChanged = $0 { false } else { true } })
    }

    public func observe(_ handler: @escaping @MainActor (FolderEvent) -> Void) -> ObserverToken { observers.add(handler) }

    // MARK: Internal helpers

    func emit(_ event: FolderEvent) {
        guard !closed else { return }
        observers.send(event)
    }

    func setState(_ new: FolderState) {
        guard new != state else { return }
        state = new
        emit(.state(new))
    }

    /// Sends a reset for the current order and carries selection across it.
    func publishReset() {
        let before = selection
        reconcileSelection(emitting: false)
        emit(.changes(.reset))
        if selection != before { emit(.selection(selection)) }
    }

    /// Runs store-mutating work one after another on the main actor.
    func enqueue(_ op: @escaping @MainActor () async -> Void) {
        let previous = opTail
        opTail = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, !self.closed, !Task.isCancelled else { return }
            await op()
        }
    }

    private func clearRows() {
        store = EntryStore(identityMode: store.identityMode)
        keysTag = 0
        rowsPresented = false
        emit(.changes(.reset))
        reconcileSelection()
    }

    // MARK: Fresh load (start, retry)

    private func beginLoad() {
        readTask?.cancel()
        pacerTask?.cancel()
        generation = generation.next()
        epoch += 1
        rowsPresented = false
        rereadInFlight = false
        rereadPending = false
        let gen = generation, directory = self.directory, worker = self.worker, query = self.query
        let identityMode = store.identityMode
        var options = ReadOptions()
        permissionAsked = context.permissionPending(directory)
        options.permissionPending = permissionAsked
        let source = readSource
        PerfSignposts.signposter.emitEvent(PerfSignposts.navigate)
        readTask = Task { @MainActor [weak self] in
            await worker.begin(gen, identityMode: identityMode, query: query)
            let stream = await source(directory, gen, options)
            for await event in stream {
                guard let self, !self.closed, self.generation == gen else { break }
                await self.handleLoad(event, gen)
            }
        }
        startPacer(gen)
    }

    private func startPacer(_ gen: Generation) {
        let pacer = context.pacer, worker = self.worker
        pacerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await pacer.nextFrame()
                guard let self, !Task.isCancelled, self.isLoading(gen) else { return }
                guard let order = await worker.takeLoadingOrder(gen) else { continue }
                guard !Task.isCancelled, self.isLoading(gen) else { return }
                self.presentLoading(order)
            }
        }
    }

    private func isLoading(_ gen: Generation) -> Bool {
        guard !closed, generation == gen else { return false }
        switch state {
        case .loading, .partial, .unresponsive, .waitingForPermission: return true
        case .complete, .error: return false
        }
    }

    private func presentLoading(_ order: [UInt32]) {
        if !rowsPresented { PerfSignposts.signposter.emitEvent(PerfSignposts.firstBatch) }
        store.setOrder(order)
        rowsPresented = true
        publishReset()
        if state == .loading { setState(.partial) }
    }

    private func handleLoad(_ event: ReadEvent, _ gen: Generation) async {
        switch event {
        case .batch(let batch):
            guard batch.generation == gen else { return }
            store.append(batch)
            await worker.ingest(batch)
        case .stalled:
            setState(.unresponsive)
        case .waitingForPermission:
            setState(.waitingForPermission)
        case .resumed:
            if state == .unresponsive || state == .waitingForPermission { setState(rowsPresented ? .partial : .loading) }
        case .completed:
            guard let (order, tag) = await worker.finishLoad(gen, query: query), !closed, generation == gen else { return }
            pacerTask?.cancel()
            pacerTask = nil
            store.setOrder(order)
            keysTag = tag
            rowsPresented = true
            if permissionAsked { context.recordPermissionOutcome(directory, true) }
            publishReset()
            setState(.complete)
            startWatcher()
            flushDeferred()
            flushWatchBuffer()
        case .failed(let failure):
            pacerTask?.cancel()
            pacerTask = nil
            await worker.cancel()
            guard !closed, generation == gen else { return }
            if failure.code == EPERM && failure.stage != .unresponsiveVolume { context.recordPermissionOutcome(directory, false) }
            if store.count > 0 || rowsPresented { clearRows() }
            watchBuffer = WatchBuffer()
            setState(FolderState(failure))
        }
    }

    // MARK: Store replacement (patches and re-reads)

    /// Adopts a worker result: new store, replacements carried, selection reconciled, the diff published.
    /// `carrying` maps old identities to the names they now have (renames on name-identity volumes).
    func applyPatch(_ result: FolderWorker.PatchResult, carrying: [(RowID, String)] = []) {
        let before = selection
        store = result.store
        keysTag = result.tag
        for replacement in result.diff.replacements { substitute(replacement.old, with: replacement.new) }
        for (old, name) in carrying {
            if let index = store.firstIndex(named: name, caseSensitive: caseSensitive) { substitute(old, with: store.identity(index)) }
        }
        reconcileSelection(emitting: false)
        if !result.diff.changes.isEmpty { emit(.changes(result.diff.changes)) }
        if selection != before { emit(.selection(selection)) }
    }

    /// Full re-read + diff of a complete folder (refresh, watcher full rescan, readItems failure). At most one runs,
    /// plus one pending that absorbs later requests. State stays .complete while it streams.
    func beginReread() {
        guard !closed, state == .complete else { return }
        if rereadInFlight { rereadPending = true; return }
        rereadInFlight = true
        namesPatchedDuringReread = []
        generation = generation.next()
        let gen = generation, directory = self.directory, worker = self.worker, query = self.query
        let identityMode = store.identityMode
        var options = ReadOptions()
        options.permissionPending = context.permissionPending(directory)
        let source = readSource
        readTask = Task { @MainActor [weak self] in
            await worker.begin(gen, identityMode: identityMode, query: query)
            let stream = await source(directory, gen, options)
            for await event in stream {
                guard let self, !self.closed, self.generation == gen else { break }
                await self.handleReread(event, gen)
            }
        }
    }

    private func handleReread(_ event: ReadEvent, _ gen: Generation) async {
        switch event {
        case .batch(let batch):
            guard batch.generation == gen else { return }
            await worker.ingest(batch)
        case .stalled, .waitingForPermission, .resumed:
            break                                   // the rows on screen stay; nothing is pending for the user
        case .completed:
            let epoch = self.epoch
            enqueue { [weak self] in
                guard let self, epoch == self.epoch, self.generation == gen else { return }
                let old = self.store
                guard let result = await self.worker.finishReread(gen, old: old, query: self.query) else { return }
                guard !self.closed, epoch == self.epoch, self.store.version == old.version else { return }
                self.applyPatch(result)
                self.rereadDone()
                self.satisfyPending()
            }
        case .failed(let failure):
            await worker.cancel()
            guard !closed, generation == gen else { return }
            rereadInFlight = false
            rereadPending = false
            clearRows()
            setState(FolderState(failure))
        }
    }

    private func rereadDone() {
        rereadInFlight = false
        let names = namesPatchedDuringReread
        namesPatchedDuringReread = []
        if !names.isEmpty { enqueuePatch(names.sorted(), renames: []) }
        if rereadPending {
            rereadPending = false
            beginReread()
        }
    }

    func stopWatcher() {
        watcher?.stop()
        watcher = nil
    }

    private func startWatcher() {
        guard watcher == nil, !closed, !relocated else { return }
        let w = context.makeWatcher(directory, startEventID) { [weak self] event in
            Task { @MainActor in self?.handleWatch(event) }
        }
        watcher = w
        w.start()
    }
}
