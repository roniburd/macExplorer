import CoreServices
import Foundation
import MacxFS

/// On-demand folder sizes (§11 Phase 2): one shared cache, and one `FolderSizeSession` per folder view that has
/// sizes on. Sizes are cached by identity and mtime and invalidated through a recursive `SubtreeWatcher` and
/// FileOps `LocalChange`s.
@MainActor
public final class FolderSizeService {
    public let cache = FolderSizeCache()
    let lanes: LanePool
    let mountTable: MountTableStore
    let makeSubtreeWatcher: @MainActor (URL, @escaping @Sendable (SubtreeChange) -> Void) -> any ContentWatching
    let maxConcurrentScans: Int
    private var sessions: [ObjectIdentifier: WeakSession] = [:]
    private var busToken: ObserverToken?
    private struct WeakSession { weak var session: FolderSizeSession? }

    public init(lanes: LanePool, mountTable: MountTableStore, changeBus: ChangeBus,
                makeSubtreeWatcher: @escaping @MainActor (URL, @escaping @Sendable (SubtreeChange) -> Void) -> any ContentWatching,
                maxConcurrentScans: Int = 2) {
        self.lanes = lanes
        self.mountTable = mountTable
        self.makeSubtreeWatcher = makeSubtreeWatcher
        self.maxConcurrentScans = max(1, maxConcurrentScans)
        busToken = changeBus.observeAll { [weak self] change in self?.localChange(change) }
    }

    /// Starts sizing every folder row of `model`: cache hits show at once, then everything is (re)scanned.
    /// The caller keeps the session and stops it when sizes are turned off or the view leaves the folder.
    public func attach(to model: FolderModel) -> FolderSizeSession {
        sessions = sessions.filter { $0.value.session != nil }
        let session = FolderSizeSession(model: model, service: self)
        sessions[ObjectIdentifier(session)] = WeakSession(session: session)
        session.begin()
        return session
    }

    private func localChange(_ change: LocalChange) {
        let dir = ChangeBus.key(for: change.directory)
        cache.invalidateAncestors(ofDirectory: dir)
        for entry in sessions.values { entry.session?.localChange(inDirectory: dir) }
    }
}

/// The folder-size work for one FolderModel: a priority queue of folder rows (visible first), at most
/// `maxConcurrentScans` scans on `.scan` lanes, and re-queueing on mtime changes, subtree events and LocalChanges.
@MainActor
public final class FolderSizeSession {
    private struct InFlight {
        var token: UInt64
        var task: Task<Void, Never>
        /// A change arrived during the scan: rescan unless the scan started after FSEvents id `dirtySince`
        /// (`UInt64.max`: always rescan, for a LocalChange).
        var dirtySince: UInt64?
        /// The row's mtime changed during the scan: rescan unless the scan already read that mtime.
        var mtimeChanged = false
    }

    /// What one lane job saw: the FSEvents id current when it started, the folder's own mtime then, and the size.
    private struct ScanResult: Sendable { var since: UInt64; var mtime: Int64?; var size: FolderSize? }

    /// The latest finished scan of a row: events up to `since` and the folder state at `mtime` are covered.
    private struct Scanned { var since: UInt64; var mtime: Int64 }

    private unowned let service: FolderSizeService
    private weak var model: FolderModel?
    private var modelToken: ObserverToken?
    private var watcher: (any ContentWatching)?

    private var queue: [RowID] = []
    private var head = 0
    private var queued = Set<RowID>()
    private var inFlight: [RowID: InFlight] = [:]
    private var visible = Set<RowID>()
    /// The mtime each folder row was last queued for in this session: a different mtime re-queues it.
    private var known: [RowID: Int64] = [:]
    private var scanned: [RowID: Scanned] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var nextToken: UInt64 = 0
    private var stopped = false
    /// The volume stopped answering: nothing is scanned until `retry()`.
    public private(set) var halted = false

    /// Scans started so far (tests).
    private(set) var scansStarted = 0

    init(model: FolderModel, service: FolderSizeService) {
        self.model = model
        self.service = service
    }

    isolated deinit {
        for flight in inFlight.values { flight.task.cancel() }
        watcher?.stop()
        modelToken?.cancel()
        for waiter in idleWaiters { waiter.resume() }
    }

    public var pendingCount: Int { queued.count }
    public var inFlightCount: Int { inFlight.count }

    func begin() {
        guard let model else { return }
        modelToken = model.observe { [weak self] event in
            switch event {
            case .changes, .state(.complete): self?.requeueChangedRows()
            default: break
            }
        }
        let w = service.makeSubtreeWatcher(model.directory) { [weak self] change in
            Task { @MainActor in self?.subtree(change) }
        }
        watcher = w
        w.start()
        startAll()
    }

    /// Visible folders scan first. `rows` are on-screen model rows (not contiguous when grouped).
    public func setVisibleRows(_ rows: IndexSet) {
        guard let model, !stopped else { return }
        visible = Set(rows.lazy.filter { $0 < model.rowCount }.map { model.identity(atRow: $0) })
        guard !visible.isEmpty, pendingCount > 0 else { return }
        let rest = queue[head...].filter { queued.contains($0) }
        queue = rest.filter { visible.contains($0) } + rest.filter { !visible.contains($0) }
        head = 0
    }

    /// Cancels every scan, stops the subtree watcher and empties the queue. Later results are ignored.
    public func stop() {
        guard !stopped else { return }
        stopped = true
        for flight in inFlight.values { flight.task.cancel() }
        inFlight = [:]
        clearQueue()
        watcher?.stop()
        watcher = nil
        modelToken?.cancel()
        modelToken = nil
        resumeWaitersIfIdle()
    }

    /// After a volume stopped answering (or on Refresh): re-queue every folder row.
    public func retry() {
        guard !stopped else { return }
        halted = false
        known = [:]
        scanned = [:]
        startAll()
    }

    /// Returns once nothing is queued or in flight (tests).
    public func waitUntilIdle() async {
        if isIdle { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private var isIdle: Bool { stopped || (queued.isEmpty && inFlight.isEmpty) }

    // MARK: Queueing

    private struct FolderRow { var row: Int; var id: RowID; var entry: Entry }

    private func folderRows(_ model: FolderModel) -> [FolderRow] {
        var rows: [FolderRow] = []
        for row in 0..<model.rowCount {
            let entry = model.entry(atRow: row)
            guard entry.kind == .directory || entry.kind == .package else { continue }
            rows.append(FolderRow(row: row, id: model.identity(atRow: row), entry: entry))
        }
        return rows
    }

    /// Cache hits go on the model at once; misses are queued first, then hits (revalidated: deep changes do not
    /// change a folder's own mtime). Visible rows go to the front.
    private func startAll() {
        guard let model, !stopped, !halted else { return }
        var hits: [RowID: FolderSize] = [:]
        var misses: [RowID] = [], revalidate: [RowID] = []
        for folder in folderRows(model) {
            known[folder.id] = folder.entry.mtime
            if inFlight[folder.id] != nil || queued.contains(folder.id) { continue }
            if let size = service.cache.value(for: key(folder.row, model)) {
                hits[folder.id] = size
                revalidate.append(folder.id)
            } else {
                misses.append(folder.id)
            }
        }
        model.setFolderSizes(hits)
        for id in misses + revalidate { enqueue(id) }
        pump()
    }

    /// New folder rows and rows whose mtime changed are queued; rows that left the folder are unqueued or cancelled.
    private func requeueChangedRows() {
        guard let model, !stopped else { return }
        for id in Array(queued) where model.row(of: id) == nil { queued.remove(id) }
        for (id, flight) in inFlight where model.row(of: id) == nil {
            flight.task.cancel()
            inFlight[id] = nil
        }
        known = known.filter { model.row(of: $0.key) != nil }
        scanned = scanned.filter { model.row(of: $0.key) != nil }
        guard !halted else { resumeWaitersIfIdle(); return }
        var hits: [RowID: FolderSize] = [:]
        for folder in folderRows(model) where known[folder.id] != folder.entry.mtime {
            let isNew = known[folder.id] == nil
            known[folder.id] = folder.entry.mtime
            if inFlight[folder.id] != nil {
                inFlight[folder.id]?.mtimeChanged = true     // finish() rescans unless the scan read this mtime
                continue
            }
            // The model can learn of a folder's new mtime after a subtree event already rescanned it.
            if scanned[folder.id]?.mtime == folder.entry.mtime { continue }
            if isNew, let size = service.cache.value(for: key(folder.row, model)) { hits[folder.id] = size }
            enqueue(folder.id)
        }
        model.setFolderSizes(hits)
        pump()
        resumeWaitersIfIdle()
    }

    private func subtree(_ change: SubtreeChange) {
        guard let model, !stopped else { return }
        let lastEvent = watcher?.lastEventID ?? 0
        let ids: [RowID]
        switch change {
        case .all: ids = folderRows(model).map(\.id)
        case .children(let names): ids = names.compactMap { name in model.row(named: name).flatMap { folderID(atRow: $0, model) } }
        }
        for id in ids { invalidate(id, since: lastEvent) }
        pump()
    }

    /// A FileOps change in `dir` (ChangeBus.key form): the child of this folder that contains it is re-queued now.
    func localChange(inDirectory dir: String) {
        guard let model, !stopped else { return }
        let base = EventClassifier.components(model.directory.path(percentEncoded: false))
        let parts = EventClassifier.components(dir)
        guard parts.count > base.count, Array(parts.prefix(base.count)) == base,
              let row = model.row(named: parts[base.count]), let id = folderID(atRow: row, model) else { return }
        invalidate(id, since: .max)
        pump()
    }

    /// The subtree of `id` changed at FSEvents id `since` (`.max`: now). Skipped when the latest scan of the row
    /// started after that event, so one change seen by both the folder watcher (mtime) and the subtree watcher
    /// is scanned once.
    private func invalidate(_ id: RowID, since: UInt64) {
        if since != .max, since != 0, let last = scanned[id], last.since >= since { return }
        if let model, let row = model.row(of: id) { service.cache.invalidate(identity(row, model)) }
        if let flight = inFlight[id] {
            inFlight[id]?.dirtySince = max(flight.dirtySince ?? 0, since == 0 ? .max : since)
            return
        }
        scanned[id] = nil
        enqueue(id)
    }

    private func enqueue(_ id: RowID) {
        guard !halted, queued.insert(id).inserted else { return }
        if visible.contains(id) { queue.insert(id, at: head) } else { queue.append(id) }
    }

    private func clearQueue() {
        queue = []
        head = 0
        queued = []
    }

    // MARK: Scanning

    private func pump() {
        guard let model, !stopped, !halted else { return }
        let volume = model.volume?.id ?? .unknown
        while inFlight.count < service.maxConcurrentScans, head < queue.count {
            let id = queue[head]
            head += 1
            if head > 1_024, head * 2 > queue.count { queue.removeFirst(head); head = 0 }
            guard queued.remove(id) != nil, let row = model.row(of: id), folderID(atRow: row, model) != nil else { continue }
            let url = model.url(atRow: row)
            let key = key(row, model)
            let path = ChangeBus.key(for: url)
            nextToken += 1
            scansStarted += 1
            let token = nextToken, lanes = service.lanes, table = service.mountTable.current()
            let task = Task { @MainActor [weak self] in
                let outcome: Result<ScanResult, any Error>
                do {
                    outcome = .success(try await lanes.perform(on: volume, .scan) { ctx in
                        // Events up to this id happened before the scan started reading: the scan sees them.
                        let since = FSEventsGetCurrentEventId()
                        let mtime = Self.modificationTime(url)
                        return ScanResult(since: since, mtime: mtime,
                                          size: FolderSizeScanner.scan(url, context: ctx, mountTable: table))
                    })
                } catch {
                    outcome = .failure(error)
                }
                self?.finish(id, token: token, key: key, path: path, outcome)
            }
            inFlight[id] = InFlight(token: token, task: task)
        }
        if queue.count == head { queue = []; head = 0 }
    }

    private func finish(_ id: RowID, token: UInt64, key: FolderSizeKey, path: String,
                        _ outcome: Result<ScanResult, any Error>) {
        guard !stopped, let flight = inFlight[id], flight.token == token else { return }
        inFlight[id] = nil
        switch outcome {
        case .success(let result):
            guard let size = result.size else { break }      // cancelled
            // Keyed by the mtime the scan itself read: the model's copy can lag behind a subtree event.
            let mtime = result.mtime ?? key.mtime
            service.cache.store(size, for: FolderSizeKey(identity: key.identity, mtime: mtime), path: path)
            scanned[id] = Scanned(since: result.since, mtime: mtime)
            model?.setFolderSizes([id: size])
            var again = false
            if let dirty = flight.dirtySince, dirty == .max || dirty > result.since { again = true }
            if flight.mtimeChanged, let model, let row = model.row(of: id), model.entry(atRow: row).mtime != mtime { again = true }
            if again { scanned[id] = nil; enqueue(id) }
        case .failure(let error):
            if case LaneError.volumeUnresponsive = error {
                halted = true                                // cells stay "Calculating…" until retry()
                clearQueue()
            }
        }
        pump()
        resumeWaitersIfIdle()
    }

    private func resumeWaitersIfIdle() {
        guard isIdle, !idleWaiters.isEmpty else { return }
        let waiters = idleWaiters
        idleWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    /// The folder's own mtime in ns since 1970 (Entry.mtime's unit), or nil. Lane only (lstat).
    private nonisolated static func modificationTime(_ url: URL) -> Int64? {
        var st = stat()
        guard lstat(url.path(percentEncoded: false), &st) == 0 else { return nil }
        return Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
    }

    // MARK: Identity

    private func folderID(atRow row: Int, _ model: FolderModel) -> RowID? {
        let kind = model.entry(atRow: row).kind
        return kind == .directory || kind == .package ? model.identity(atRow: row) : nil
    }

    /// `.object(volume, rowID)` on idStable volumes, else the folder's path (§11: "path on non-idStable volumes").
    private func identity(_ row: Int, _ model: FolderModel) -> FolderSizeIdentity {
        if model.store.identityMode == .objectID, let volume = model.volume?.id {
            return .object(volume, model.entry(atRow: row).rowID)
        }
        return .path(ChangeBus.key(for: model.url(atRow: row)))
    }

    private func key(_ row: Int, _ model: FolderModel) -> FolderSizeKey {
        FolderSizeKey(identity: identity(row, model), mtime: model.entry(atRow: row).mtime)
    }
}
