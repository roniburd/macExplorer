import CryptoKit
import Foundation
import MacxPluginKit

/// Downloaded remote files for preview and open (spec §2.4, §4.3): `<root>/<provider>/<repo hash>/<key>/<name>`.
/// `key` is the item's `contentID` (a blob SHA names one content forever, so the entry is immutable) or, with none,
/// a hash of ref + path that is downloaded again on every request. Files are read-only (0444). When the total passes
/// `limitBytes` the least recently used key folders go first. Concurrent requests for one entry share one download,
/// which is cancelled once every request waiting for it has been cancelled.
public actor RemoteFileCache {
    public static let autoPreviewLimit: Int64 = 10 * 1024 * 1024

    public nonisolated let root: URL
    public nonisolated let limitBytes: Int64
    private struct Flight {
        var task: Task<URL, any Error>
        /// Requests waiting for `task` that have not been cancelled.
        var waiters: Int
    }
    private var inFlight: [String: Flight] = [:]

    public init(root: URL, limitBytes: Int64 = 1 << 30) {
        self.root = root
        self.limitBytes = limitBytes
    }

    public func localURL(for location: RemoteLocation, item: RemoteItem, provider: any RemoteProvider)
        async throws(RemoteError) -> URL {
        guard item.kind == .file else { throw .unsupported }
        let destination = Self.entryURL(root: root, location: location, item: item)
        let key = destination.path(percentEncoded: false)
        if let running = inFlight[key] {
            inFlight[key]?.waiters += 1
            return try await wait(for: running.task, key: key)
        }
        if item.contentID != nil, FileManager.default.fileExists(atPath: key) {
            Self.markUsed(destination)
            return destination
        }
        let partials = root.appending(path: ".partial", directoryHint: .isDirectory)
        let task = Task<URL, any Error> {
            let fm = FileManager.default
            try fm.createDirectory(at: partials, withIntermediateDirectories: true)
            let temp = partials.appending(path: UUID().uuidString, directoryHint: .notDirectory)
            do {
                try await provider.fetch(location, item: item, to: temp)
                try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: temp.path(percentEncoded: false))
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: destination.path(percentEncoded: false)) { try fm.removeItem(at: destination) }
                try fm.moveItem(at: temp, to: destination)
                Self.markUsed(destination)
                return destination
            } catch {
                try? fm.removeItem(at: temp)
                throw error
            }
        }
        inFlight[key] = Flight(task: task, waiters: 1)
        defer { if inFlight[key]?.task == task { inFlight[key] = nil } }
        let url = try await wait(for: task, key: key)
        trim()
        return url
    }

    /// Waits for a shared download; a cancelled waiter gives up its share, and the last one cancels the download.
    private func wait(for task: Task<URL, any Error>, key: String) async throws(RemoteError) -> URL {
        do {
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                Task { await self.abandon(task, key: key) }
            }
        } catch let error as RemoteError {
            throw error
        } catch {
            throw .network(error.localizedDescription)
        }
    }

    private func abandon(_ task: Task<URL, any Error>, key: String) {
        guard var flight = inFlight[key], flight.task == task else { return }
        flight.waiters -= 1
        if flight.waiters <= 0 {
            // Forget the cancelled download now so a request arriving while it unwinds starts a fresh one.
            inFlight[key] = nil
            task.cancel()
        } else {
            inFlight[key] = flight
        }
    }

    /// Bytes of every cached file (logical sizes).
    public func totalSize() -> Int64 { Self.entries(root: root).reduce(0) { $0 + $1.size } }

    /// Removes the least recently used key folders until the total fits `limitBytes`.
    public func trim() {
        var entries = Self.entries(root: root)
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > limitBytes else { return }
        entries.sort { $0.used < $1.used }
        for entry in entries where total > limitBytes {
            if (try? FileManager.default.removeItem(at: entry.url)) != nil { total -= entry.size }
        }
    }

    /// Settings › Connections › Clear Cache. A download still running then fails and is retried on the next request.
    public func clear() {
        let fm = FileManager.default
        for child in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: child)
        }
    }

    // MARK: layout

    public nonisolated static func entryURL(root: URL, location: RemoteLocation, item: RemoteItem) -> URL {
        let key = item.contentID.map(safeComponent) ?? sha256("\(location.ref ?? "")\u{0}\(location.pathString)")
        return root.appending(path: safeComponent(location.provider), directoryHint: .isDirectory)
            .appending(path: String(sha256(location.repo).prefix(16)), directoryHint: .isDirectory)
            .appending(path: key, directoryHint: .isDirectory)
            .appending(path: item.name, directoryHint: .notDirectory)
    }

    nonisolated static func safeComponent(_ s: String) -> String {
        String(s.map { $0 == "/" || $0 == ":" ? "_" : $0 })
    }

    nonisolated static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Recency is the key folder's mtime (the file itself is read-only).
    nonisolated static func markUsed(_ file: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()],
                                               ofItemAtPath: file.deletingLastPathComponent().path(percentEncoded: false))
    }

    struct Entry { var url: URL; var size: Int64; var used: Date }

    /// Every `<provider>/<repo>/<key>` folder with its size and last use (`.partial` excluded).
    nonisolated static func entries(root: URL) -> [Entry] {
        let fm = FileManager.default
        func children(_ url: URL) -> [URL] { (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [] }
        var result: [Entry] = []
        for provider in children(root) where provider.lastPathComponent != ".partial" {
            for repo in children(provider) {
                for key in children(repo) {
                    let used = (try? key.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                        ?? .distantPast
                    let size = children(key).reduce(Int64(0)) {
                        $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                    }
                    result.append(Entry(url: key, size: size, used: used))
                }
            }
        }
        return result
    }
}
