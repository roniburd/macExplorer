import Foundation
import MacxFS

/// Routes LocalChange posts (FileOps, §4.3) to the FolderModels showing each directory.
@MainActor
public final class ChangeBus {
    private var observers: [String: [(id: UInt64, handler: @MainActor (LocalChange) -> Void)]] = [:]
    private var nextID: UInt64 = 0

    public init() {}

    /// Delivers each change to the observers of its directory, in registration order.
    public func post(_ changes: [LocalChange]) {
        for change in changes {
            for entry in observers[Self.key(for: change.directory)] ?? [] { entry.handler(change) }
        }
    }

    /// Keys are the standardized path WITHOUT a trailing slash, and /private/var ≡ /var: LocalChange.directory carries
    /// a trailing slash (URL(filePath:directoryHint: .isDirectory)) while observers register the folder's own URL
    /// (S3 Contract note 16; P1-25's end-to-end test fails otherwise).
    public func observe(directory: URL, _ handler: @escaping @MainActor (LocalChange) -> Void) -> ObserverToken {
        nextID += 1
        let id = nextID, key = Self.key(for: directory)
        observers[key, default: []].append((id, handler))
        return ObserverToken { [weak self] in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.remove(id, key) }
            } else {
                Task { @MainActor in self?.remove(id, key) }
            }
        }
    }

    /// Lexical standardization (no file-system access): "." and ".." resolved, no trailing slash, and a leading
    /// "/private" dropped before var, tmp or etc (the firmlinked spellings).
    public nonisolated static func key(for url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        var parts = path.split(separator: "/", omittingEmptySubsequences: true)
        if parts.count >= 2, parts[0] == "private", ["var", "tmp", "etc"].contains(parts[1]) { parts.removeFirst() }
        return "/" + parts.joined(separator: "/")
    }

    private func remove(_ id: UInt64, _ key: String) {
        observers[key]?.removeAll { $0.id == id }
        if observers[key]?.isEmpty == true { observers[key] = nil }
    }
}
