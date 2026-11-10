import Foundation
import Darwin
import MacxFS

/// Where a tag query looks (P4-06): every indexed volume (Spotlight) or one folder subtree.
public enum TagScope: Sendable, Equatable { case thisMac, directory(URL) }

/// A tag query's output: `results` are cumulative (each one replaces the previous list); `finished` comes once, when
/// the first full pass ends (a Spotlight query keeps updating after it).
public enum TagQueryUpdate: Sendable, Equatable { case results([URL]), finished }

/// Finds the items that carry a tag (case-insensitively). Iterating the stream runs the query; ending the iteration
/// (or cancelling the iterating task) stops it.
public protocol TagQuerying: Sendable {
    func results(for tagName: String, scope: TagScope) -> AsyncStream<TagQueryUpdate>
}

/// A tag query that walks one folder subtree and reads each item's tags (no Spotlight): sandboxed runs, scenarios
/// and tests. `.thisMac` finishes at once with no results. The walk runs on a read lane under no-materialization,
/// never follows symlinks or crosses into other volumes, and doesn't enter packages (a tagged package itself is found).
public struct CrawlTagQuery: TagQuerying {
    static let emitEvery = 256
    static let emitInterval = Duration.milliseconds(100)

    private let lanes: LanePool
    private let volume: VolumeID
    private let types: TypeRegistry

    public init(lanes: LanePool, volume: VolumeID = .unknown, types: TypeRegistry = .shared) {
        self.lanes = lanes
        self.volume = volume
        self.types = types
    }

    public func results(for tagName: String, scope: TagScope) -> AsyncStream<TagQueryUpdate> {
        let (stream, continuation) = AsyncStream.makeStream(of: TagQueryUpdate.self, bufferingPolicy: .unbounded)
        guard case .directory(let root) = scope else {
            continuation.yield(.results([]))
            continuation.yield(.finished)
            continuation.finish()
            return stream
        }
        let wanted = tagName.lowercased()
        let task = Task { [lanes, volume, types] in
            let walked: Bool? = try? await lanes.perform(on: volume, .read) { lane in
                withNoMaterialization {
                    Self.crawl(root, wanted: wanted, types: types, lane: lane) { continuation.yield(.results($0)) }
                }
                return true
            }
            if walked == nil { continuation.yield(.results([])) }      // cancelled before the walk, or the lane failed
            continuation.yield(.finished)
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Lane only. Emits the cumulative matches every `emitEvery` matches or `emitInterval`, and once at the end
    /// (also when cancelled, with what was found so far).
    static func crawl(_ root: URL, wanted: String, types: TypeRegistry, lane: LaneContext, emit: ([URL]) -> Void) {
        var found: [URL] = []
        var lastEmit = ContinuousClock.now
        var seen = 0
        defer { emit(found) }
        guard let path = strdup(root.path(percentEncoded: false)) else { return }
        defer { free(path) }
        var argv: [UnsafeMutablePointer<CChar>?] = [path, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return }
        defer { fts_close(fts) }
        while let ent = fts_read(fts) {
            seen += 1
            if seen % 256 == 0 {
                lane.heartbeat()
                if lane.isCancelled { return }
            }
            let info = Int32(ent.pointee.fts_info)
            if info == FTS_DP || info == FTS_DNR || info == FTS_ERR || info == FTS_NS || info == FTS_DC { continue }
            if ent.pointee.fts_level == 0 { continue }                       // the scope folder itself isn't a result
            let p = String(cString: ent.pointee.fts_path)
            let isDirectory = info == FTS_D
            if isDirectory, types.isPackage(types.index(forExtension: Substring((p as NSString).pathExtension), isDirectory: true)) {
                fts_set(fts, ent, FTS_SKIP)
            }
            let url = URL(filePath: p, directoryHint: isDirectory ? .isDirectory : .notDirectory)
            guard ((try? TagIO.read(url)) ?? []).contains(where: { $0.name.lowercased() == wanted }) else { continue }
            found.append(url)
            if found.count % emitEvery == 0 || ContinuousClock.now - lastEmit > emitInterval {
                emit(found)
                lastEmit = .now
            }
        }
    }
}

/// A live Spotlight tag query (`kMDItemUserTags ==[c] name`) over This Mac or one folder. The NSMetadataQuery runs on
/// its own serial queue (`QueryRun`, Phase 3's confinement), never on main. Results are cumulative, coalesced to at
/// most one update per 100 ms; `.finished` follows the end of gathering, then updates keep coming until the stream's
/// consumer stops. Tests never start it: they test `predicate(for:)` and feed scripted events through `init(run:)`.
public struct SpotlightTagQuery: TagQuerying {
    typealias Runner = @Sendable (_ tagName: String, _ scope: TagScope) -> AsyncStream<MetadataQueryEvent>
    static let coalesceInterval = Duration.milliseconds(100)

    private let run: Runner

    public init() { run = { Self.system($0, $1) } }
    init(run: @escaping Runner) { self.run = run }

    static func predicate(for tagName: String) -> NSPredicate {
        NSPredicate(format: "%K ==[c] %@", "kMDItemUserTags", tagName)
    }

    static func metadataScope(_ scope: TagScope) -> MetadataScope {
        switch scope {
        case .thisMac: .localComputer
        case .directory(let url): .folders([url])
        }
    }

    private static func system(_ tagName: String, _ scope: TagScope) -> AsyncStream<MetadataQueryEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: MetadataQueryEvent.self, bufferingPolicy: .unbounded)
        let query = QueryRun(predicate: { predicate(for: tagName) }, scope: metadataScope(scope), continuation: continuation)
        continuation.onTermination = { _ in query.stop() }
        query.start()
        return stream
    }

    public func results(for tagName: String, scope: TagScope) -> AsyncStream<TagQueryUpdate> {
        let (stream, out) = AsyncStream.makeStream(of: TagQueryUpdate.self, bufferingPolicy: .unbounded)
        let events = run(tagName, scope)
        let task = Task {
            let results = CumulativeResults(out: out, interval: Self.coalesceInterval)
            for await event in events {
                switch event {
                case .added(let items), .updated(let items): await results.add(items.map(\.path))
                case .removed(let paths): await results.remove(paths)
                case .gatheringFinished: await results.finishGathering()
                case .failed:
                    await results.finishGathering()
                    out.finish()
                    return
                }
            }
            await results.finishGathering()
            out.finish()
        }
        out.onTermination = { _ in task.cancel() }
        return stream
    }
}

/// The cumulative path set of a live query, in first-seen order, yielded at most once per `interval` (a change inside
/// the interval schedules one trailing yield).
private actor CumulativeResults {
    private let out: AsyncStream<TagQueryUpdate>.Continuation
    private let interval: Duration
    private var order: [String: Int] = [:]
    private var counter = 0
    private var dirty = false
    private var emittedOnce = false
    private var finished = false
    private var lastEmit: ContinuousClock.Instant?
    private var flushScheduled = false

    init(out: AsyncStream<TagQueryUpdate>.Continuation, interval: Duration) {
        self.out = out
        self.interval = interval
    }

    func add(_ paths: [String]) {
        for path in paths where order[path] == nil {
            order[path] = counter
            counter += 1
            dirty = true
        }
        changed()
    }

    func remove(_ paths: [String]) {
        for path in paths where order.removeValue(forKey: path) != nil { dirty = true }
        changed()
    }

    /// Yields the current list now (at least once, even when empty) and `.finished` the first time.
    func finishGathering() {
        if dirty || !emittedOnce { flush() }
        if !finished {
            finished = true
            out.yield(.finished)
        }
    }

    private func changed() {
        guard dirty else { return }
        let now = ContinuousClock.now
        guard let last = lastEmit, now - last < interval else { return flush() }
        guard !flushScheduled else { return }
        flushScheduled = true
        let wait = interval - (now - last)
        Task {
            try? await Task.sleep(for: wait)
            self.scheduledFlush()
        }
    }

    private func scheduledFlush() {
        flushScheduled = false
        if dirty { flush() }
    }

    private func flush() {
        dirty = false
        emittedOnce = true
        lastEmit = .now
        out.yield(.results(order.sorted { $0.value < $1.value }.map { URL(filePath: $0.key) }))
    }
}
