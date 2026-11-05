import CoreServices
import Foundation
import Synchronization

/// Recursive FSEventStream on one folder for folder-size invalidation (§11 Phase 2): NoDefer | WatchRoot, no
/// FileEvents (directory granularity), events from the moment `start()` is called (the stream itself opens later, on
/// its queue, and replays what happened in between), 1 s latency. Each delivery is classified by
/// `SubtreeEventClassifier` on the stream's private queue and non-nil results go to `handler` on that queue.
public final class SubtreeWatcher: ContentWatching {
    private struct State {
        var started = false
        var stopped = false
        var lastEventID: UInt64 = 0
        var since: UInt64 = 0
        var folderPath: String
    }

    private let directory: URL
    private let latency: Duration
    private let handler: @Sendable (SubtreeChange) -> Void
    private let box = FSEventStreamBox(label: "macx.subtree-watcher")
    private let state: Mutex<State>

    public init(directory: URL, latency: Duration = .seconds(1), handler: @escaping @Sendable (SubtreeChange) -> Void) {
        self.directory = directory
        self.latency = latency
        self.handler = handler
        state = Mutex(State(folderPath: directory.path(percentEncoded: false)))
    }

    /// The newest event id delivered so far (0 before the first delivery). Set before `handler` runs.
    public var lastEventID: UInt64 { state.withLock { $0.lastEventID } }

    public func start() {
        let now = FSEventsGetCurrentEventId()
        let go = state.withLock { s -> Bool in
            guard !s.started, !s.stopped else { return false }
            s.started = true
            s.since = now
            return true
        }
        guard go else { return }
        box.queue.async { [self] in open() }
    }

    /// Idempotent. No handler call starts after stop returns.
    public func stop() {
        let wasRunning = state.withLock { s -> Bool in
            defer { s.stopped = true }
            return s.started && !s.stopped
        }
        guard wasRunning else { return }
        box.queue.async { [box] in box.close() }
    }

    /// On the box's queue.
    private func open() {
        guard !state.withLock({ $0.stopped }) else { return }
        let path = FSEventStreamBox.realPath(directory.path(percentEncoded: false))
        state.withLock { $0.folderPath = path }
        let since = state.withLock { $0.since }
        let opened = box.open(path: path, since: since, latency: latency,
                              flags: kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot) { [weak self] events in
            self?.receive(events)
        }
        // Cannot watch: sizes stay as scanned (the session still re-queues on mtime changes and LocalChanges).
        guard opened else { return }
        if state.withLock({ $0.stopped }) { box.close() }
    }

    /// On the box's queue.
    private func receive(_ events: [RawFSEvent]) {
        let folder = state.withLock { s -> String? in
            guard !s.stopped else { return nil }
            for e in events where e.id > s.lastEventID { s.lastEventID = e.id }
            return s.folderPath
        }
        guard let folder, let change = SubtreeEventClassifier.classify(events, folder: folder) else { return }
        guard !state.withLock({ $0.stopped }) else { return }
        handler(change)
    }
}
