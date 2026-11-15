import Foundation
import Dispatch

public enum JournalEntry: Sendable, Codable, Equatable {
    case partial(job: JobID, url: URL)
    case trashedDestination(job: JobID, original: URL, trashURL: URL)
    case twoStepRename(job: JobID, temporary: URL, original: URL, target: URL)
    case jobStarted(job: JobID, description: JobDescription)
    /// A batch rename's plan, recorded before its first rename (P4-11). Launch recovery puts every item back.
    case batchRename(job: JobID, steps: [BatchRenameStep])

    public var job: JobID {
        switch self {
        case .partial(let j, _), .trashedDestination(let j, _, _), .twoStepRename(let j, _, _, _), .jobStarted(let j, _),
             .batchRename(let j, _): j
        }
    }
}

/// One item of a batch rename: original → temporary (phase 1) → target (phase 2). `identity` is the item's (lstat).
public struct BatchRenameStep: Sendable, Codable, Equatable {
    public var original: URL
    public var temporary: URL
    public var target: URL
    public var identity: FileIdentity
    public init(original: URL, temporary: URL, target: URL, identity: FileIdentity) {
        self.original = original; self.temporary = temporary; self.target = target; self.identity = identity
    }
}

/// Crash journal (§6.3). Rewritten atomically (Data.write .atomic = temp file + rename) on every change.
/// Its executor is a private serial DispatchQueue, so these small blocking writes never run on the
/// cooperative pool or the main thread.
public actor Journal {
    private struct FileFormat: Codable {
        var version = 1
        var entries: [JournalEntry]
        /// Launches at which LaunchRecovery kept some of the job's entries for a later try (absent in older files).
        var recoveryAttempts: [JobID: Int]? = nil
    }

    private let fileURL: URL
    private let executorQueue: DispatchSerialQueue
    private var items: [JournalEntry] = []
    private var attempts: [JobID: Int] = [:]
    private var loaded = false

    public nonisolated var unownedExecutor: UnownedSerialExecutor { executorQueue.asUnownedSerialExecutor() }

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.executorQueue = DispatchSerialQueue(label: "com.macexplorer.journal")
    }

    public func record(_ entry: JournalEntry) throws {
        loadIfNeeded()
        items.append(entry)
        try persist()
    }

    public func clear(_ entry: JournalEntry) throws {
        loadIfNeeded()
        if let i = items.firstIndex(of: entry) { items.remove(at: i) }
        try persist()
    }

    /// Drops every entry of `job` except `kept` (entries the next launch's recovery must still see).
    public func finish(job: JobID, keeping kept: [JournalEntry] = []) throws {
        loadIfNeeded()
        let before = items.count
        items.removeAll { $0.job == job && !kept.contains($0) }
        let hadAttempts = attempts.removeValue(forKey: job) != nil
        if items.count != before || hadAttempts { try persist() }
    }

    /// LaunchRecovery: of `job`'s entries only `kept` (the ones it could not act on yet) stay, for the next launch.
    /// Returns how many launches have kept entries of this job, this one included.
    @discardableResult
    public func retainForNextLaunch(job: JobID, keeping kept: [JournalEntry]) throws -> Int {
        loadIfNeeded()
        items.removeAll { $0.job == job && !kept.contains($0) }
        let n = (attempts[job] ?? 0) + 1
        attempts[job] = n
        try persist()
        return n
    }

    public func entries() -> [JournalEntry] {
        loadIfNeeded()
        return items
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? JSONDecoder().decode(FileFormat.self, from: data) {
            items = decoded.entries
            attempts = decoded.recoveryAttempts ?? [:]
        } else {
            // Our own file but unreadable: set it aside (never delete it) and start empty.
            let stamp = Int(Date().timeIntervalSince1970)
            let aside = fileURL.deletingLastPathComponent().appending(path: "journal.corrupt-\(stamp).json")
            try? FileManager.default.moveItem(at: fileURL, to: aside)
        }
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(FileFormat(entries: items, recoveryAttempts: attempts.isEmpty ? nil : attempts))
        try data.write(to: fileURL, options: .atomic)
    }
}
