import Foundation

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
/// The file is small and only used with `--state-dir`; each `set` rewrites it atomically.
/// A missing or unreadable file is an empty store.
@MainActor public final class FileSettingsStorage: SettingsStorage {
    public let fileURL: URL
    private var values: [String: Data]

    public init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: Data].self, from: data) {
            values = decoded
        } else {
            values = [:]
        }
    }

    public func data(forKey key: String) -> Data? { values[key] }

    public func set(_ data: Data?, forKey key: String) {
        values[key] = data
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(values) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
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
