//
// CONFINEMENT EXCEPTION (Phase 1 Global Constraints): `QueryRun` is `@unchecked Sendable`. Its NSMetadataQuery,
// notification observers and bookkeeping are created, read, mutated and torn down only on `queue`, a private
// serial OperationQueue that is also the query's `operationQueue` and the observers' delivery queue. Callers only
// call `start()`/`stop()`, which enqueue onto `queue`. Nothing else in this file is unchecked, and NSMetadataQuery
// never touches the main thread.
import Foundation

public final class SystemMetadataQuery: MetadataQuerying {
    /// Test hook: called on the query's queue at `begin` and at every notification (tests check it is never main).
    let onQueue: (@Sendable (String) -> Void)?
    public init() { onQueue = nil }
    init(onQueue: @escaping @Sendable (String) -> Void) { self.onQueue = onQueue }

    public func run(_ request: SpotlightRequest) -> AsyncStream<MetadataQueryEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: MetadataQueryEvent.self, bufferingPolicy: .unbounded)
        let run = QueryRun(request: request, continuation: continuation, onQueue: onQueue)
        continuation.onTermination = { _ in run.stop() }
        run.start()
        return stream
    }
}

final class QueryRun: @unchecked Sendable {
    private let queue = OperationQueue()
    /// Built on `queue` at `begin` (NSPredicate isn't Sendable).
    private let makePredicate: @Sendable () -> NSPredicate
    private let scope: MetadataScope
    private let continuation: AsyncStream<MetadataQueryEvent>.Continuation
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var delivered = 0
    private var paths: [ObjectIdentifier: String] = [:]
    private var stopped = false
    private let onQueue: (@Sendable (String) -> Void)?

    convenience init(request: SpotlightRequest, continuation: AsyncStream<MetadataQueryEvent>.Continuation,
                     onQueue: (@Sendable (String) -> Void)? = nil) {
        self.init(predicate: { SpotlightPredicate.make(request) }, scope: request.scope, continuation: continuation,
                  onQueue: onQueue)
    }

    /// Any predicate (P4-06 tag queries) with the same confinement, batching and event mapping.
    init(predicate: @escaping @Sendable () -> NSPredicate, scope: MetadataScope,
         continuation: AsyncStream<MetadataQueryEvent>.Continuation, onQueue: (@Sendable (String) -> Void)? = nil) {
        makePredicate = predicate
        self.scope = scope
        self.continuation = continuation
        self.onQueue = onQueue
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        queue.name = "com.macexplorer.spotlight"
    }

    func start() { queue.addOperation { self.begin() } }
    func stop() { queue.addOperation { self.end() } }

    private func begin() {
        guard !stopped else { return }
        onQueue?("begin")
        let q = NSMetadataQuery()
        q.operationQueue = queue
        q.predicate = makePredicate()
        switch scope {
        case .localComputer: q.searchScopes = [NSMetadataQueryLocalComputerScope]
        case .folders(let urls): q.searchScopes = urls
        }
        q.notificationBatchingInterval = 0.1
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .NSMetadataQueryGatheringProgress, object: q, queue: queue) { _ in
                self.onQueue?("progress")
                self.drainGathered()
            },
            center.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: q, queue: queue) { _ in
                self.onQueue?("finished")
                self.drainGathered()
                self.continuation.yield(.gatheringFinished)
            },
            center.addObserver(forName: .NSMetadataQueryDidUpdate, object: q, queue: queue) { note in
                self.onQueue?("update")
                self.update(note.userInfo)
            },
        ]
        query = q
        if !q.start() {
            continuation.yield(.failed)
            continuation.finish()
            end()
        }
    }

    private func drainGathered() {
        guard let q = query else { return }
        q.disableUpdates()
        defer { q.enableUpdates() }
        let count = q.resultCount
        guard count > delivered else { return }
        var items: [MetadataItem] = []
        for i in delivered..<count {
            guard let raw = q.result(at: i) as? NSMetadataItem, let item = Self.convert(raw) else { continue }
            paths[ObjectIdentifier(raw)] = item.path
            items.append(item)
        }
        delivered = count
        if !items.isEmpty { continuation.yield(.added(items)) }
    }

    private func update(_ info: [AnyHashable: Any]?) {
        func items(_ key: String) -> [NSMetadataItem] { info?[key] as? [NSMetadataItem] ?? [] }
        let added = items(NSMetadataQueryUpdateAddedItemsKey).compactMap { raw -> MetadataItem? in
            guard let item = Self.convert(raw) else { return nil }
            paths[ObjectIdentifier(raw)] = item.path
            return item
        }
        var moved: [String] = []                       // renamed / moved: the old path leaves the results
        let changed = items(NSMetadataQueryUpdateChangedItemsKey).compactMap { raw -> MetadataItem? in
            guard let item = Self.convert(raw) else { return nil }
            if let old = paths.updateValue(item.path, forKey: ObjectIdentifier(raw)), old != item.path { moved.append(old) }
            return item
        }
        let removed = moved + items(NSMetadataQueryUpdateRemovedItemsKey).compactMap { raw -> String? in
            paths.removeValue(forKey: ObjectIdentifier(raw)) ?? (raw.value(forAttribute: NSMetadataItemPathKey) as? String)
        }
        if !added.isEmpty { continuation.yield(.added(added)) }
        if !changed.isEmpty { continuation.yield(.updated(changed)) }
        if !removed.isEmpty { continuation.yield(.removed(removed)) }
    }

    private func end() {
        stopped = true
        query?.stop()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        query = nil
    }

    static func convert(_ item: NSMetadataItem) -> MetadataItem? {
        guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { return nil }
        let name = item.value(forAttribute: NSMetadataItemFSNameKey) as? String ?? (path as NSString).lastPathComponent
        return MetadataItem(path: path, name: name,
                            size: (item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value,
                            modified: item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date,
                            created: item.value(forAttribute: NSMetadataItemFSCreationDateKey) as? Date,
                            contentTypeTree: item.value(forAttribute: NSMetadataItemContentTypeTreeKey) as? [String] ?? [],
                            isInvisible: item.value(forAttribute: "kMDItemFSInvisible") as? Bool ?? false)
    }
}
