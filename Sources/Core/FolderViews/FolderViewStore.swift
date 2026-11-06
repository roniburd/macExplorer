import Foundation

/// MacExplorer's per-folder view choices (design 2026-11-05 §2), keyed by standardized path and persisted as JSON.
/// Least recently used entries beyond `limit` are dropped. Writes are debounced; `flush()` writes now.
/// A file that fails to decode is moved aside (".corrupt") and the store starts empty.
@MainActor
public final class FolderViewStore {
    public static let defaultLimit = 5_000

    struct Entry: Codable, Equatable {
        var settings: FolderViewSettings
        var lastUsed: Double     // seconds since 1970
    }

    struct File: Codable {
        var version = 1
        var folders: [String: Entry] = [:]
    }

    private let fileURL: URL?
    private let limit: Int
    private let now: () -> Date
    private let saveDelay: Duration
    private var folders: [String: Entry] = [:]
    private var saveTask: Task<Void, Never>?

    /// `fileURL` nil = in memory only (tests, sandbox scenarios).
    public init(fileURL: URL?, limit: Int = FolderViewStore.defaultLimit, saveDelay: Duration = .seconds(1),
                now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.limit = limit
        self.now = now
        self.saveDelay = saveDelay
        load()
    }

    /// Standardized absolute path without a trailing slash ("/" stays "/").
    public nonisolated static func key(_ url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    public var count: Int { folders.count }

    /// The folder's settings (nil when it has none); marks it used.
    public func settings(for folder: URL) -> FolderViewSettings? {
        let key = Self.key(folder)
        guard var entry = folders[key] else { return nil }
        entry.lastUsed = now().timeIntervalSince1970
        folders[key] = entry
        return entry.settings
    }

    /// Applies `change` to the folder's settings (creating them); an empty result removes the entry.
    public func update(_ folder: URL, _ change: (inout FolderViewSettings) -> Void) {
        let key = Self.key(folder)
        var settings = folders[key]?.settings ?? FolderViewSettings()
        change(&settings)
        if settings.isEmpty {
            folders[key] = nil
        } else {
            folders[key] = Entry(settings: settings, lastUsed: now().timeIntervalSince1970)
            evict()
        }
        scheduleSave()
    }

    public func remove(_ folder: URL) {
        guard folders.removeValue(forKey: Self.key(folder)) != nil else { return }
        scheduleSave()
    }

    /// Writes pending changes now (app termination).
    public func flush() {
        saveTask?.cancel()
        saveTask = nil
        save()
    }

    // MARK: private

    private func evict() {
        guard folders.count > limit else { return }
        let drop = folders.sorted { $0.value.lastUsed < $1.value.lastUsed }.prefix(folders.count - limit)
        for (key, _) in drop { folders[key] = nil }
    }

    private func scheduleSave() {
        guard fileURL != nil, saveTask == nil else { return }
        let delay = saveDelay
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.saveTask = nil
            self.save()
        }
    }

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        if let file = try? JSONDecoder().decode(File.self, from: data) {
            folders = file.folders
            evict()
        } else {
            let aside = fileURL.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: fileURL, to: aside)
        }
    }

    private func save() {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(File(folders: folders)) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
