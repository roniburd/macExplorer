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
    /// The groups of the order about to be published (P2-09): after each regroup, immediately before its
    /// `.changes(.reset)`. Empty when grouping was turned off.
    case groups([GroupRun])
    /// These rows' folder sizes changed (P2-13; views show them from P2-14).
    case folderSizes(Set<RowID>)
    /// These rows' extended attributes (tags, last opened, permissions, owner, comment) were read (P2-15).
    case extendedAttributes(Set<RowID>)
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
    /// "Now" and the calendar for Date Modified groups (P2-09); tests inject both.
    public var now: @Sendable () -> Date
    public var calendar: Calendar
    /// While folder sizes stream in, the size sort re-sorts at most once per this interval (P2-14); tests pass .zero.
    public var resortCoalescing: Duration
    /// uid → user name for the Owner column (P2-15); CoreEnvironment shares one cache across folders.
    public var ownerNames: OwnerNameCache
    /// Items of a folder changed outside the model's own patches (watcher events, F5): the names, or nil when the
    /// change can't be pinned to names (full rescan, root changed, refresh). CoreEnvironment drops the TagCache
    /// entries (P4-05: tags edited by Finder or other apps, paths reused).
    public var itemsChanged: @MainActor (_ directory: URL, _ names: [String]?) -> Void

    public init(readers: DirectoryReaders, lanes: LanePool, volumes: Volumes, changeBus: ChangeBus,
                types: TypeRegistry = .shared, pacer: any FramePacer = TimerFramePacer(),
                makeWatcher: @escaping @MainActor (URL, UInt64, @escaping @Sendable (WatchEvent) -> Void) -> any ContentWatching,
                permissionPending: @escaping @MainActor (URL) -> Bool,
                recordPermissionOutcome: @escaping @MainActor (URL, Bool) -> Void,
                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                now: @escaping @Sendable () -> Date = { Date() },
                calendar: Calendar = .autoupdatingCurrent,
                resortCoalescing: Duration = .milliseconds(500),
                ownerNames: OwnerNameCache = OwnerNameCache(),
                itemsChanged: @escaping @MainActor (_ directory: URL, _ names: [String]?) -> Void = { _, _ in }) {
        self.itemsChanged = itemsChanged
        self.home = home
        self.ownerNames = ownerNames
        self.resortCoalescing = resortCoalescing
        self.now = now
        self.calendar = calendar
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
    /// Not main-actor isolated: a fresh load starts reading while main still finishes the navigation turn.
    typealias ReadSource = @Sendable (URL, Generation, ReadOptions) async -> AsyncStream<ReadEvent>
    typealias ItemSource = @MainActor ([String], URL, Generation) async throws -> ItemReadResult

    public let directory: URL
    public private(set) var state: FolderState = .loading
    public private(set) var store: EntryStore {
        didSet { pruneFolderSizes(); storeChangedForAttributes() }
    }
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
    /// Watcher patch coalescing (FolderModel+Watch): one patch in flight, later item events wait in `watchPending`.
    var watchPatchInFlight = false
    var watchPending = WatchBuffer()
    var relocated = false

    // The read in progress
    private var readTask: Task<Void, Never>?
    private var pacerTask: Task<Void, Never>?
    /// Fresh loads hand batches to the worker through this feed, consumed off main in order, so the main actor
    /// never waits for a batch sort before taking the next batch (QA round 1: busy display cycles between those
    /// hops made a 100k listing take 3-5x the model-level time).
    private var loadFeed: AsyncStream<Batch>.Continuation?
    private var loadFeeder: Task<Void, Never>?
    private var permissionAsked = false
    private var rowsPresented = false
    /// Incremented by every fresh load (start, retry): store-mutating work captured under an older epoch is dropped.
    private(set) var epoch = 0
    /// Keys tag of `store` in the worker (FolderWorker.KeysTag).
    var keysTag: FolderWorker.KeysTag = 0

    // Serialized store mutations after the first listing (re-sorts, patch and re-read results). No I/O runs in
    // this queue: item reads happen before their patch is enqueued, so a hung lane cannot hold up a re-sort.
    private var opTail: Task<Void, Never>?
    /// Item reads (FolderModel+Changes): issue counter and, per identity name, the newest read that covers it.
    var itemReadSeq = 0
    var latestItemRead: [String: Int] = [:]
    var itemReadsInFlight = 0
    /// Per identity name, item reads issued and not yet applied or dropped (FolderModel+Changes `reconcile`).
    var unappliedItemReads: [String: Int] = [:]
    /// `reconcile` callbacks waiting until no read, and no coalesced watcher event, still covers their names.
    var settleWaiters: [(names: Set<String>, then: @MainActor () -> Void)] = []
    /// Renames carried by item reads not yet applied, by read seq: a later read of either side covers both.
    var unappliedRenames: [Int: [LocalChange.Rename]] = [:]
    var rereadInFlight = false
    var rereadPending = false
    /// The re-read in flight reported .stalled/.waitingForPermission and has not resumed.
    var rereadStalled = false
    var namesPatchedDuringReread: Set<String> = []
    var deferredChanges: [LocalChange] = []
    var pendingSelect: [String] = []
    var pendingRename: String?
    /// Localized stems by real name ("" = none); refresh() clears it. FolderModel+LocalizedNames.
    var localizedNameCache: [String: String] = [:]
    var localizedNamesTask: Task<Void, Never>?

    // Group by (FolderModel+Grouping, P2-09)
    public internal(set) var grouping: GroupBy = .none
    /// Groups of the current display order; empty when not grouped.
    public internal(set) var groups: [GroupRun] = []
    /// Bumped by every grouping change and new-day regroup: results computed for an older one are redone.
    var groupingRevision = 0
    var dateBuckets: DateBuckets
    var dayTask: Task<Void, Never>?

    // Folder sizes (FolderModel+Sizes, P2-13): set by a FolderSizeSession; rows that leave the store are dropped.
    var sizeTable: [RowID: FolderSize] = [:]
    /// "Calculate Folder Sizes" is on for the view showing this model (P2-14): the selection total includes folders.
    public internal(set) var folderSizesEnabled = false
    /// The pending coalesced size re-sort (FolderModel+Sizes).
    var sizeResortTask: Task<Void, Never>?
    /// `selectionSummary`'s cached walk, kept current by `setFolderSizes`.
    var selectionTotals: SelectionTotals?
    // Extended attributes (FolderModel+Attributes, P2-15), by identity; rows that leave the store are dropped.
    var attributeTable: [RowID: ExtendedAttributes] = [:]
    /// Entries the watcher or a patch invalidated, with the `attributeSerial` of that invalidation. They keep
    /// their values (no blank cells) until a read that began after it replaces them.
    var staleAttributes: [RowID: Int] = [:]
    var attributeSerial = 0
    var lastAttributeRequest: AttributeRequest?
    /// The one attribute read in flight, and the latest request made meanwhile.
    var attributeTask: Task<Void, Never>?
    var pendingAttributeRequest: AttributeRequest?
    var attributeRefreshScheduled = false
    /// Sorting by an extended column (FolderModel+ExtendedSort, P2-16): the load of every row's value before the
    /// re-sort, and the coalesced re-sort after values change while sorted by one.
    var extendedSortTask: Task<Void, Never>?
    var columnResortTask: Task<Void, Never>?
    /// The extended sort field's values by identity (compact: one 8-byte value per row, string keys interned; review
    /// fix, §4.4 memory), kept current per changed identity and handed to the worker without a walk. Built for
    /// `sortColumnField`; nil when not sorted by one. `attributeTable` holds only the rows views asked for.
    var sortColumnField: SortField?
    var sortColumn: ExtraColumnValues?
    /// Column entries the watcher or a patch invalidated, with the `attributeSerial` of that invalidation; they keep
    /// their value (and position) until a read that began after it lands.
    var staleSortValues: [RowID: Int] = [:]
    /// A full invalidation (F5, full rescan) happened: the next `startExtendedSort` re-reads every row once.
    var sortColumnRefreshPending = false
    /// Names read for the sort column so far (tests).
    var sortValueReads = 0
    /// Full builds of the sort column so far (tests).
    var sortColumnBuilds = 0
    /// Sort-only reads (FolderModel+Attributes): identities whose sort value must be (re-)read, and the read task.
    var pendingSortReads: Set<RowID> = []
    var sortReadTask: Task<Void, Never>?
    /// Full selection walks so far (tests).
    private(set) var selectionSummaryPasses = 0

    public init(directory: URL, context: FolderContext, query: ViewQuery) {
        self.directory = directory
        self.context = context
        self.query = query
        let mode = context.volumes.volume(for: directory)?.capabilities.identityMode ?? .objectID
        self.store = EntryStore(identityMode: mode)
        self.openedVolume = context.volumes.volume(for: directory)?.id
        self.worker = FolderWorker(types: context.types)
        self.dateBuckets = DateBuckets(now: context.now(), calendar: context.calendar)
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
    /// A re-read that stalled (hung volume, pending permission) is abandoned and a new one starts.
    public func refresh() {
        guard started, !closed else { return }
        switch state {
        case .complete:
            if rereadInFlight && rereadStalled { abandonReread() }
            invalidateAllExtendedAttributes()       // F5 re-reads the visible rows' attributes too (P2-15)
            context.itemsChanged(directory, nil)
            localizedNameCache = [:]
            beginReread()
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
        localizedNamesTask?.cancel()
        pacerTask?.cancel()
        opTail?.cancel()
        stopLoadFeed()
        readTask = nil
        resetItemReads()
        pacerTask = nil
        stopWatcher()
        cancelDayTimer()
        sizeResortTask?.cancel()
        sizeResortTask = nil
        cancelExtendedAttributes()
        cancelExtendedSort()
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
    /// The real file-system name (operations, rename, paths).
    public func name(atRow row: Int) -> String { store.name(store.storageIndex(forRow: row)) }
    /// The name shown in lists (design 2026-11-05 §1): Finder-hidden extensions and localized names applied.
    public func displayName(atRow row: Int) -> String {
        store.displayName(store.storageIndex(forRow: row), showAllExtensions: query.showAllExtensions)
    }

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

    /// Display rows of `names` in one pass over the store (QA round 1); names hidden from the view are left out.
    public func rows(named names: [String]) -> IndexSet {
        IndexSet(store.firstIndices(named: names, caseSensitive: caseSensitive).values.compactMap { store.row(ofStorageIndex: $0) })
    }

    public func errno(atRow row: Int) -> Int32? { store.errno(store.storageIndex(forRow: row)) }

    // MARK: Query

    /// Re-sort/filter off main; one .changes(.reset). An extended sort field (P2-16) first loads that field for
    /// every row (rows keep their order until then; FolderModel+ExtendedSort).
    public func setQuery(_ query: ViewQuery) {
        guard query != self.query else { return }
        let leavesExtended = self.query.sort.field.isExtended && !query.sort.field.isExtended
        self.query = query
        emit(.query(query))
        cancelExtendedSort()
        if leavesExtended { trimAttributesAfterExtendedSort() }
        switch state {
        case .loading, .partial, .unresponsive, .waitingForPermission:
            let worker = self.worker
            Task { await worker.setLoadingQuery(query) }
        case .complete:
            if query.sort.field.isExtended {
                startExtendedSort()
            } else {
                enqueue { [weak self] in await self?.resortNow() }
            }
        case .error:
            break
        }
    }

    /// Re-sort (and regroup when grouped) of a complete folder: one `.groups` (when grouped) and one reset.
    func resortNow() async {
        let snapshot = store, wanted = query, epoch = self.epoch, group = currentGroupSpec()
        let signpost = PerfSignposts.signposter.beginInterval(PerfSignposts.sort)
        let result = await worker.resort(snapshot, tag: keysTag, query: wanted, group: group, values: sortValues())
        PerfSignposts.signposter.endInterval(PerfSignposts.sort, signpost)
        // A newer setQuery or grouping change queued its own re-sort; a fresh load replaced the store.
        guard !closed, epoch == self.epoch, wanted == query, store.version == snapshot.version,
              result.revision == groupingRevision else { return }
        store.setOrder(result.order)
        setGroups(result.runs)
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

    /// Files' bytes, plus (with folder sizes on) the selected folders' and packages' computed sizes once every one
    /// of them is known (P2-14).
    /// One walk of the selection per (selection, store version, sizes toggle); folder sizes arriving afterwards
    /// update the cached totals in `setFolderSizes` (§11: selection totals are computed incrementally).
    public var selectionSummary: SelectionSummary {
        if let totals = selectionTotals, totals.selection == selection, totals.storeVersion == store.version,
           totals.sizesEnabled == folderSizesEnabled {
            return totals.summary
        }
        selectionSummaryPasses += 1
        var files = 0, folders = 0, sizable = 0, sized = 0
        var bytes: Int64 = 0, folderSum: Int64 = 0
        for row in selection.rows {
            let e = entry(atRow: row)
            switch e.kind {
            case .directory, .package:
                if e.kind == .directory { folders += 1 } else { files += 1 }   // a package's size is its entry count
                sizable += 1
                if let size = folderSize(atRow: row) { sized += 1; folderSum += size.bytes }
            default: files += 1; bytes += e.size
            }
        }
        let totals = SelectionTotals(selection: selection, storeVersion: store.version, sizesEnabled: folderSizesEnabled,
                                     base: SelectionSummary(count: selection.count, files: files, folders: folders, bytes: bytes),
                                     sizable: sizable, sized: sized, folderSum: folderSum)
        selectionTotals = totals
        return totals.summary
    }

    public func isCut(row: Int) -> Bool { !cutNames.isEmpty && cutNames.contains(name(atRow: row)) }

    var rowSpace: SelectionRowSpace {
        SelectionRowSpace(count: rowCount, identity: { [unowned self] in identity(atRow: $0) },
                          row: { [unowned self] in row(of: $0) }, rowsNamed: { [unowned self] in rows(named: $0) })
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

    /// Waits for the store-mutating work queued so far (tests: a finished extended-sort load enqueues its re-sort,
    /// which lands only after this).
    func drainQueuedWork() async {
        await opTail?.value
    }

    /// A fresh load drops every item read in flight (their epoch is stale and they never claim).
    func resetItemReads() {
        latestItemRead = [:]
        itemReadsInFlight = 0
        unappliedItemReads = [:]
        settleWaiters = []
        unappliedRenames = [:]
        resetWatchPatches()
    }

    private func clearRows() {
        store = EntryStore(identityMode: store.identityMode)
        keysTag = 0
        rowsPresented = false
        setGroups([])
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
        rereadStalled = false
        resetItemReads()
        resetExtendedAttributes()
        let gen = generation, directory = self.directory, worker = self.worker, query = self.query
        let identityMode = store.identityMode
        var options = ReadOptions()
        permissionAsked = context.permissionPending(directory)
        options.permissionPending = permissionAsked
        let source = readSource
        PerfSignposts.signposter.emitEvent(PerfSignposts.navigate)
        stopLoadFeed()
        let (feed, feedInput) = AsyncStream<Batch>.makeStream()
        loadFeed = feedInput
        // Starts the worker and the read off main (QA round 1): navigating keeps main busy with UI for tens of ms,
        // and the read used to wait for that before it even began.
        let opening = Task.detached(priority: .userInitiated) { () -> AsyncStream<ReadEvent> in
            await worker.begin(gen, identityMode: identityMode, query: query)
            return await source(directory, gen, options)
        }
        readTask = Task { @MainActor [weak self] in
            let stream = await opening.value
            do {
                guard let self, !self.closed, self.generation == gen else { return }
                self.loadFeeder = Task.detached(priority: .userInitiated) {
                    for await batch in feed { await worker.ingest(batch) }
                }
            }
            for await event in stream {
                guard let self, !self.closed, self.generation == gen else { break }
                await self.handleLoad(event, gen)
            }
        }
        startPacer(gen)
    }

    /// Ends the current load's feed; batches not yet ingested belong to a stale generation and are dropped.
    private func stopLoadFeed() {
        loadFeed?.finish()
        loadFeed = nil
        loadFeeder?.cancel()
        loadFeeder = nil
    }

    /// Waits until the worker has ingested every batch fed so far (the feed is finished first).
    private func drainLoadFeed() async {
        loadFeed?.finish()
        loadFeed = nil
        await loadFeeder?.value
        loadFeeder = nil
    }

    private func startPacer(_ gen: Generation) {
        let pacer = context.pacer, worker = self.worker
        pacerTask = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            var nextPresent = clock.now
            while !Task.isCancelled {
                await pacer.nextFrame()
                guard let self, !Task.isCancelled, self.isLoading(gen) else { return }
                guard clock.now >= nextPresent else { continue }
                guard let result = await worker.takeLoadingOrder(gen, group: self.currentGroupSpec()) else { continue }
                guard !Task.isCancelled, self.isLoading(gen) else { return }
                self.presentLoading(result.order, runs: result.runs)
                nextPresent = clock.now + Self.loadingPresentSpacing(rows: result.order.count)
            }
        }
    }

    /// Minimum time between two loading presentations (§4.3 allows at most one per frame). Each one is a full
    /// reloadData plus a re-layout of the visible rows; for a large folder doing that every frame kept the main
    /// actor too busy to take the remaining batches, so 100k entries took ~1.5 s to list (QA round 1). Small
    /// folders still update every frame; the first batch is always presented at once, and a large local folder
    /// usually completes before a second one is due (a slow volume still shows progress 4× a second).
    nonisolated static func loadingPresentSpacing(rows: Int) -> Duration {
        rows < 5_000 ? .zero : .milliseconds(250)
    }

    private func isLoading(_ gen: Generation) -> Bool {
        guard !closed, generation == gen else { return false }
        switch state {
        case .loading, .partial, .unresponsive, .waitingForPermission: return true
        case .complete, .error: return false
        }
    }

    private func presentLoading(_ order: [UInt32], runs: [GroupRun]) {
        if !rowsPresented { PerfSignposts.signposter.emitEvent(PerfSignposts.firstBatch) }
        store.setOrder(order)
        rowsPresented = true
        setGroups(runs)
        publishReset()
        if state == .loading { setState(.partial) }
    }

    private func handleLoad(_ event: ReadEvent, _ gen: Generation) async {
        switch event {
        case .batch(let batch):
            guard batch.generation == gen else { return }
            store.append(batch)
            loadFeed?.yield(batch)
        case .stalled:
            setState(.unresponsive)
        case .waitingForPermission:
            setState(.waitingForPermission)
        case .resumed:
            if state == .unresponsive || state == .waitingForPermission { setState(rowsPresented ? .partial : .loading) }
        case .completed:
            await drainLoadFeed()
            guard !closed, generation == gen else { return }
            guard let finished = await worker.finishLoad(gen, query: query, group: currentGroupSpec(), values: sortValues()),
                  !closed, generation == gen else { return }
            pacerTask?.cancel()
            pacerTask = nil
            store.setOrder(finished.order)
            keysTag = finished.tag
            rowsPresented = true
            if permissionAsked { context.recordPermissionOutcome(directory, true) }
            setGroups(finished.runs)
            publishReset()
            setState(.complete)
            if finished.revision != groupingRevision { regroup() }
            scheduleLocalizedNames()
            startWatcher()
            flushDeferred()
            flushWatchBuffer()
            startExtendedSort()             // sorted by an extended column: load its values, then re-sort
        case .failed(let failure):
            pacerTask?.cancel()
            pacerTask = nil
            stopLoadFeed()
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
        let old = store
        store = result.store
        keysTag = result.tag
        for replacement in result.diff.replacements { substitute(replacement.old, with: replacement.new) }
        let carried = store.firstIndices(named: carrying.map(\.1), caseSensitive: caseSensitive)
        for (old, name) in carrying {
            if let index = carried[name] { substitute(old, with: store.identity(index)) }
        }
        reconcileSelection(emitting: false)
        pruneAttributes(old: old, diff: result.diff)
        invalidateReloadedAttributes(result.diff.changes)
        publishPatch(result.diff.changes, runs: result.runs)
        if selection != before { emit(.selection(selection)) }
        if result.groupRevision != groupingRevision { regroup() }
        scheduleLocalizedNames()
    }

    /// Like applyPatch without re-scheduling localized names (a localized-name patch never adds candidates).
    func applyLocalizedPatch(_ result: FolderWorker.PatchResult) {
        let before = selection
        store = result.store
        keysTag = result.tag
        reconcileSelection(emitting: false)
        publishPatch(result.diff.changes, runs: result.runs)
        if selection != before { emit(.selection(selection)) }
        if result.groupRevision != groupingRevision { regroup() }
    }

    /// Full re-read + diff of a complete folder (refresh, watcher full rescan, readItems failure). At most one runs,
    /// plus one pending that absorbs later requests. State stays .complete while it streams.
    func beginReread() {
        guard !closed, state == .complete else { return }
        if rereadInFlight { rereadPending = true; return }
        rereadInFlight = true
        rereadStalled = false
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
        case .stalled, .waitingForPermission:
            rereadStalled = true                    // the rows on screen stay; refresh() abandons this read
        case .resumed:
            rereadStalled = false
        case .completed:
            let epoch = self.epoch
            enqueue { [weak self] in
                guard let self, epoch == self.epoch, self.generation == gen else { return }
                let old = self.store
                guard let result = await self.worker.finishReread(gen, old: old, query: self.query,
                                                                  group: self.currentGroupSpec(),
                                                                  values: self.sortValues()) else { return }
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
            rereadStalled = false
            clearRows()
            setState(FolderState(failure))
        }
    }

    /// Drops a stalled re-read: its stream is no longer consumed and its late results carry a stale generation.
    /// The worker's half-built listing is replaced by the next `begin` (cancelling it here could race that begin).
    private func abandonReread() {
        readTask?.cancel()
        readTask = nil
        rereadInFlight = false
        rereadPending = false
        rereadStalled = false
    }

    private func rereadDone() {
        rereadInFlight = false
        rereadStalled = false
        let names = namesPatchedDuringReread
        namesPatchedDuringReread = []
        if !names.isEmpty { enqueuePatch(names.sorted(), renames: []) }
        startExtendedSort()                 // new rows lack the sort column's values
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
