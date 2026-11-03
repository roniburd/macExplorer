import CoreServices
import Darwin
import Foundation
import Synchronization

/// One FSEventStream on the visible folder (§4.3 Watcher): FileEvents | NoDefer | WatchRoot, 100 ms latency,
/// delivered on a private serial queue, classified there, and handed to `handler` on that queue.
/// The stream is created and torn down on that queue, never on main.
public final class Watcher: ContentWatching {
    public static func currentEventID() -> UInt64 { FSEventsGetCurrentEventId() }

    private struct State {
        var started = false
        var stopped = false
        var lastEventID: UInt64
        var folderPath: String
    }

    /// Context info for the C callback; holds the watcher weakly so a live stream never keeps it alive.
    private final class Callback: Sendable {
        let deliver: @Sendable ([RawFSEvent]) -> Void
        init(_ deliver: @escaping @Sendable ([RawFSEvent]) -> Void) { self.deliver = deliver }
    }

    private let directory: URL
    private let since: UInt64
    private let latency: Duration
    private let handler: @Sendable (WatchEvent) -> Void
    private let queue = DispatchQueue(label: "macx.watcher", qos: .utility)
    private let state: Mutex<State>
    /// Only touched on `queue` (and in deinit, when nothing else can reach it).
    nonisolated(unsafe) private var stream: FSEventStreamRef?

    /// FileEvents|NoDefer|WatchRoot, latency 100 ms, private serial queue. Handler is called on that queue.
    /// `since` is the FSEvents ID captured before the folder's read (0 = from now).
    public init(directory: URL, since eventID: UInt64, latency: Duration = .milliseconds(100),
                handler: @escaping @Sendable (WatchEvent) -> Void) {
        self.directory = directory
        self.since = eventID
        self.latency = latency
        self.handler = handler
        state = Mutex(State(lastEventID: eventID, folderPath: directory.path(percentEncoded: false)))
    }

    deinit {
        // stop() normally ran; a dropped watcher must not leave a stream behind.
        if let stream { Self.teardown(stream) }
    }

    public var lastEventID: UInt64 { state.withLock { $0.lastEventID } }

    public func start() {
        let go = state.withLock { s -> Bool in
            guard !s.started, !s.stopped else { return false }
            s.started = true
            return true
        }
        guard go else { return }
        queue.async { [self] in open() }
    }

    /// Idempotent. No handler call starts after stop returns.
    public func stop() {
        let wasRunning = state.withLock { s -> Bool in
            defer { s.stopped = true }
            return s.started && !s.stopped
        }
        guard wasRunning else { return }
        queue.async { [self] in
            guard let stream else { return }
            self.stream = nil
            Self.teardown(stream)
        }
    }

    private static func teardown(_ stream: FSEventStreamRef) {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    /// On `queue`.
    private func open() {
        guard !state.withLock({ $0.stopped }) else { return }
        // FSEvents reports real paths; resolve once here (off main) so the parent filter compares like with like.
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let path: String
        if realpath(directory.path(percentEncoded: false), &buffer) != nil {
            path = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        } else {
            path = directory.path(percentEncoded: false)
        }
        state.withLock { $0.folderPath = path }

        let callback = Callback { [weak self] events in self?.receive(events) }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passRetained(callback).toOpaque(), retain: nil,
                                           release: { info in
                                               if let info { Unmanaged<Callback>.fromOpaque(info).release() }
                                           }, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes)
        let sinceWhen = since == 0 ? FSEventStreamEventId(kFSEventStreamEventIdSinceNow) : since
        let seconds = Double(latency.components.seconds) + Double(latency.components.attoseconds) / 1e18
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, { _, info, count, paths, flags, ids in
            guard let info else { return }
            let callback = Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self)
            var events: [RawFSEvent] = []
            events.reserveCapacity(count)
            for i in 0..<count {
                guard let path = array[i] as? String else { continue }
                events.append(RawFSEvent(path: path, flags: flags[i], id: ids[i]))
            }
            callback.deliver(events)
        }, &context, [path] as CFArray, sinceWhen, seconds, flags) else {
            handler(.fullRescan)                        // cannot watch: one re-read keeps the view honest
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            handler(.fullRescan)
            return
        }
        if state.withLock({ $0.stopped }) {
            Self.teardown(stream)            // stop() ran while we opened; its teardown block found nothing
        } else {
            self.stream = stream
        }
    }

    /// On `queue`.
    private func receive(_ events: [RawFSEvent]) {
        let folder = state.withLock { s -> String? in
            guard !s.stopped else { return nil }
            for e in events where e.id > s.lastEventID { s.lastEventID = e.id }
            return s.folderPath
        }
        guard let folder, let event = EventClassifier.classify(events, folder: folder) else { return }
        guard !state.withLock({ $0.stopped }) else { return }
        handler(event)
    }
}
