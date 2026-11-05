import Darwin
import Foundation
import MacxFS

/// Watcher events that arrived while the listing streamed (§4.3 No gap), applied once it completes.
struct WatchBuffer: Equatable {
    private(set) var names: [String] = []
    private var seen: Set<String> = []
    private(set) var rescan = false
    private(set) var rootChanged = false

    var isEmpty: Bool { names.isEmpty && !rescan && !rootChanged }

    /// The buffered events, condensed (root change, else rescan, else the names).
    var events: [WatchEvent] {
        if rootChanged { return [.rootChanged] }
        if rescan { return [.fullRescan] }
        return names.isEmpty ? [] : [.items(names)]
    }

    mutating func add(_ event: WatchEvent) {
        switch event {
        case .items(let new):
            for name in new where seen.insert(name).inserted { names.append(name) }
            if names.count > EventClassifier.incrementalLimit { rescan = true }
        case .fullRescan: rescan = true
        case .rootChanged: rootChanged = true
        }
    }
}

/// What a probe of the folder found after RootChanged / ItemRemoved|ItemRenamed on it.
enum RootProbe: Sendable, Equatable {
    case present                    // still a directory at that path (replaced or touched): re-read it
    case gone(ancestor: URL)        // nearest existing ancestor directory
}

/// Watcher → model (§4.3): buffering during reads, incremental ≤256 patches, one full re-read plus one pending,
/// root changed → relocate to the nearest existing ancestor, volume gone → home.
extension FolderModel {
    /// Called on main for every classified event of this model's watcher.
    func handleWatch(_ event: WatchEvent) {
        guard !closed, !relocated else { return }
        // Before any patch: an xattr-only change (tags, comment) leaves mtime alone, so the store diff reports
        // nothing; the event itself is what re-reads the item's extended attributes (P2-15, Review Focus 2).
        invalidateExtendedAttributes(for: event)
        switch state {
        case .complete: applyWatch(event)
        case .loading, .partial, .unresponsive, .waitingForPermission: watchBuffer.add(event)
        case .error: if event == .rootChanged { checkRoot() }
        }
    }

    private func applyWatch(_ event: WatchEvent) {
        switch event {
        case .items(let names):
            if watchPatchInFlight { watchPending.add(event) } else { startWatchPatch(names) }
        case .fullRescan: beginReread()
        case .rootChanged: checkRoot()
        }
    }

    /// FSEvents with NoDefer delivers a burst as many small deliveries, and every patch re-sorts and diffs the
    /// whole folder. So at most one watcher patch runs; item events arriving meanwhile coalesce into one follow-up
    /// patch, or one re-read past the incremental limit (§4.4 FSEvent → UI updated).
    private func startWatchPatch(_ names: [String]) {
        watchPatchInFlight = true
        let epoch = self.epoch
        enqueuePatch(names, renames: []) { [weak self] in self?.watchPatchDone(epoch: epoch) }
    }

    private func watchPatchDone(epoch: Int) {
        guard epoch == self.epoch else { return }
        let pending = watchPending
        watchPending = WatchBuffer()
        watchPatchInFlight = false
        for event in pending.events { handleWatch(event) }
    }

    /// A fresh load re-reads everything: drop the coalescing state of the previous epoch.
    func resetWatchPatches() {
        watchPatchInFlight = false
        watchPending = WatchBuffer()
    }

    /// After a fresh load completed: what the buffer gathered becomes one root check, one re-read or one patch.
    func flushWatchBuffer() {
        let buffer = watchBuffer
        watchBuffer = WatchBuffer()
        guard !buffer.isEmpty else { return }
        if buffer.rootChanged {
            checkRoot()
        } else if buffer.rescan {
            beginReread()
        } else {
            enqueuePatch(buffer.names, renames: [])
        }
    }

    /// Stats the folder on a lane: still there → full re-read; gone → relocate to the nearest existing ancestor.
    func checkRoot() {
        let directory = self.directory, lanes = context.lanes
        let volume = openedVolume ?? .unknown
        Task { @MainActor [weak self] in
            let probe = try? await lanes.perform(on: volume) { _ in Self.probe(directory) }
            guard let self, !self.closed, !self.relocated, let probe else { return }
            switch probe {
            case .present:
                if self.state == .complete { self.beginReread() } else { self.watchBuffer.add(.fullRescan) }
            case .gone(let ancestor):
                if let volume = self.openedVolume, !self.context.volumes.list.isEmpty,
                   !self.context.volumes.list.contains(where: { $0.id == volume }) {
                    self.relocate(to: self.context.home, reason: .volumeGone)
                } else {
                    self.relocate(to: ancestor, reason: .movedOrDeleted(name: directory.lastPathComponent))
                }
            }
        }
    }

    /// The window opened a folder that isn't there (history, breadcrumb, › menu, a stale path) and it ended in
    /// .error(.notFound | .volumeGone): relocate to the nearest existing ancestor (or Home) like a removed root,
    /// so the window never shows a silent blank list (§4.3, QA round 2).
    public func relocateIfGone() {
        guard !closed, !relocated, case .error(let reason) = state, reason == .notFound || reason == .volumeGone
        else { return }
        checkRoot()
    }

    /// Volume list changed: the folder's volume is no longer mounted → Home.
    func volumesChanged(_ list: [VolumeInfo]) {
        guard !closed, !relocated, let volume = openedVolume, !list.isEmpty else { return }
        if !list.contains(where: { $0.id == volume }) { relocate(to: context.home, reason: .volumeGone) }
    }

    /// Emitted once; the watcher stops (the window navigates and opens a new model).
    func relocate(to url: URL, reason: RelocationReason) {
        guard !relocated, !closed else { return }
        relocated = true
        stopWatcher()
        watchBuffer = WatchBuffer()
        emit(.relocate(to: url, reason: reason))
    }

    /// Lane work: is `directory` still a directory, else the nearest existing ancestor directory.
    nonisolated static func probe(_ directory: URL) -> RootProbe {
        func isDirectory(_ url: URL) -> Bool {
            var st = stat()
            return stat(url.path(percentEncoded: false), &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
        }
        if isDirectory(directory) { return .present }
        var candidate = directory.standardizedFileURL
        while candidate.path(percentEncoded: false) != "/" {
            candidate = candidate.deletingLastPathComponent()
            if isDirectory(candidate) { return .gone(ancestor: candidate) }
        }
        return .gone(ancestor: URL(filePath: "/", directoryHint: .isDirectory))
    }
}
