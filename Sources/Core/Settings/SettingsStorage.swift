import Foundation
import Synchronization

/// Key → opaque bytes. `Settings` JSON-encodes each value under its own key.
@MainActor public protocol SettingsStorage: AnyObject {
    func data(forKey key: String) -> Data?
    /// `nil` removes the key.
    func set(_ data: Data?, forKey key: String)
}

/// The app's real store. Tests and harnesses never use it (they use `InMemorySettingsStorage` or `FileSettingsStorage`).
@MainActor public final class UserDefaultsStorage: SettingsStorage {
    private let defaults: UserDefaults
    public init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func data(forKey key: String) -> Data? { defaults.data(forKey: key) }
    public func set(_ data: Data?, forKey key: String) {
        if let data { defaults.set(data, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

/// A single JSON file (`<state-dir>/settings.json`) holding every key, used in sandbox and scenario mode.
/// The dictionary lives on main; `set` does no file I/O (§4.4). Writes are coalesced (`debounce`, 250 ms) and the
/// encode + atomic write run on a private serial writer queue, so a column-resize drag costs one write.
/// `flush()` writes synchronously (termination); releasing the store flushes what is pending.
/// Exception (documented): `init` reads the small local file once, synchronously, at launch.
/// A missing or unreadable file is an empty store.
@MainActor public final class FileSettingsStorage: SettingsStorage {
    public let fileURL: URL
    private var values: [String: Data]
    private let debounce: Duration
    private let writer: Writer
    private var scheduled: Task<Void, Never>?

    public init(fileURL: URL, debounce: Duration = .milliseconds(250)) {
        self.fileURL = fileURL
        self.debounce = debounce
        self.writer = Writer(fileURL: fileURL)
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: Data].self, from: data) {
            values = decoded
        } else {
            values = [:]
        }
    }

    deinit {
        let writer = self.writer
        writer.queue.sync { writer.writePending() }
    }

    public func data(forKey key: String) -> Data? { values[key] }

    public func set(_ data: Data?, forKey key: String) {
        values[key] = data
        writer.stage(values)
        guard scheduled == nil else { return }
        let writer = self.writer, debounce = self.debounce
        scheduled = Task { @MainActor [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self?.scheduled = nil
            writer.queue.async { writer.writePending() }
        }
    }

    /// Writes anything pending now, on the writer queue, and waits for it (app termination).
    public func flush() {
        scheduled?.cancel()
        scheduled = nil
        let writer = self.writer
        writer.queue.sync { writer.writePending() }
    }

    /// Test inspection: completed file writes, and whether the last one ran on the main thread.
    var writeCount: Int { writer.stats.withLock { $0.count } }
    var lastWriteWasOnMain: Bool { writer.stats.withLock { $0.onMain } }

    /// Owns the latest staged snapshot; only `queue` encodes and writes it.
    private final class Writer: Sendable {
        let fileURL: URL
        let queue = DispatchQueue(label: "macx.settings-writer", qos: .utility)
        private let pending = Mutex<[String: Data]?>(nil)
        let stats = Mutex<(count: Int, onMain: Bool)>((0, false))

        init(fileURL: URL) { self.fileURL = fileURL }

        func stage(_ values: [String: Data]) { pending.withLock { $0 = values } }

        /// On `queue`.
        func writePending() {
            guard let values = pending.withLock({ p -> [String: Data]? in defer { p = nil }; return p }) else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            guard let data = try? encoder.encode(values) else { return }
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
            let onMain = Thread.isMainThread
            stats.withLock { $0 = ($0.count + 1, onMain) }
        }
    }
}

/// Test store.
@MainActor public final class InMemorySettingsStorage: SettingsStorage {
    private var values: [String: Data] = [:]
    public init() {}
    public func data(forKey key: String) -> Data? { values[key] }
    public func set(_ data: Data?, forKey key: String) { values[key] = data }
    /// Stored keys, sorted (test inspection).
    public var keys: [String] { values.keys.sorted() }
}
