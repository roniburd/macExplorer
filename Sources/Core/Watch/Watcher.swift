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

    private let directory: URL
    private let since: UInt64
    private let latency: Duration
    private let handler: @Sendable (WatchEvent) -> Void
    private let box = FSEventStreamBox(label: "macx.watcher")
    private var queue: DispatchQueue { box.queue }
    private let state: Mutex<State>

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
        queue.async { [box] in box.close() }
    }

    /// On `queue`.
    private func open() {
        guard !state.withLock({ $0.stopped }) else { return }
        // FSEvents reports real paths; resolve once here (off main) so the parent filter compares like with like.
        let path = FSEventStreamBox.realPath(directory.path(percentEncoded: false))
        state.withLock { $0.folderPath = path }

        let opened = box.open(path: path, since: since, latency: latency,
                              flags: kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                                  | kFSEventStreamCreateFlagWatchRoot) { [weak self] events in self?.receive(events) }
        guard opened else {
            handler(.fullRescan)                        // cannot watch: one re-read keeps the view honest
            return
        }
        if state.withLock({ $0.stopped }) {
            box.close()                      // stop() ran while we opened; its close block may have found nothing
            return
        }
        // The folder may have been moved or deleted after the read and before the stream existed. FSEvents does
        // not reliably replay that to a stream whose root is already gone, so check it once the stream runs:
        // later changes reach the stream, earlier ones are seen here.
        if !Self.isDirectory(path), !state.withLock({ $0.stopped }) { handler(.rootChanged) }
    }

    private static func isDirectory(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
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
