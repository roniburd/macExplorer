import Foundation
import Dispatch

public enum JournalEntry: Sendable, Codable, Equatable {
    case partial(job: JobID, url: URL)
    case trashedDestination(job: JobID, original: URL, trashURL: URL)
    case twoStepRename(job: JobID, temporary: URL, original: URL, target: URL)
    case jobStarted(job: JobID, description: JobDescription)

    public var job: JobID {
        switch self {
        case .partial(let j, _), .trashedDestination(let j, _, _), .twoStepRename(let j, _, _, _), .jobStarted(let j, _): j
        }
    }
}

/// Crash journal (§6.3). Rewritten atomically (Data.write .atomic = temp file + rename) on every change.
/// Its executor is a private serial DispatchQueue, so these small blocking writes never run on the
/// cooperative pool or the main thread.
public actor Journal {
    private struct FileFormat: Codable { var version = 1; var entries: [JournalEntry] }

    private let fileURL: URL
    private let executorQueue: DispatchSerialQueue
    private var items: [JournalEntry] = []
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

    public func finish(job: JobID) throws {
        loadIfNeeded()
        let before = items.count
        items.removeAll { $0.job == job }
        if items.count != before { try persist() }
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
        } else {
            // Our own file but unreadable: set it aside (never delete it) and start empty.
            let stamp = Int(Date().timeIntervalSince1970)
            let aside = fileURL.deletingLastPathComponent().appending(path: "journal.corrupt-\(stamp).json")
            try? FileManager.default.moveItem(at: fileURL, to: aside)
        }
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(FileFormat(entries: items))
        try data.write(to: fileURL, options: .atomic)
    }
}
