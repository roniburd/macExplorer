import Foundation
import MacxPluginKit

/// Copy out of a repository (spec §4.5): downloads remote items into one fresh staging folder (folders recursively,
/// listing through the provider), so a normal copy job can then put them where the user pasted or dropped them.
/// Throws `RemoteError` or `CancellationError`; on any error the staging folder is removed. Every file and folder
/// written is quarantined (`RemoteQuarantine`), so the copies the copy job makes keep the attribute.
///
/// Trust boundary: a provider's names become local path components here, so an item whose name is not one valid
/// component (`RemoteItem.isValidName`) is refused (a dragged or copied item) or skipped (a folder's child), as is a
/// second child with the same name; nothing is ever written outside the destination.
public struct RemoteExport: Sendable {
    public struct Progress: Sendable, Equatable {
        public var itemsDone = 0
        public var bytesDone: Int64 = 0
        public var currentItem: String?
    }
    public struct Staged: Sendable, Equatable {
        public var directory: URL     // remove after the copy job finished
        public var items: [URL]       // one per source, in order
    }

    let registry: ProviderRegistry
    let stagingRoot: URL

    public init(registry: ProviderRegistry, stagingRoot: URL) {
        self.registry = registry
        self.stagingRoot = stagingRoot
    }

    /// The local name of the item at `location`: its own name, or at the repository root (whose synthetic item is
    /// named after the repo, "owner/repo") the repo's last component. nil when it is not a valid path component.
    public static func localName(_ item: RemoteItem, at location: RemoteLocation) -> String? {
        let name = location.path.isEmpty ? String(item.name.split(separator: "/").last ?? "") : item.name
        return RemoteItem.isValidName(name) ? name : nil
    }

    public func stage(_ urls: [URL], progress: @escaping @Sendable (Progress) -> Void) async throws -> Staged {
        let directory = stagingRoot.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            var state = Progress()
            var items: [URL] = []
            for url in urls {
                guard let location = RemoteLocation(url: url) else { throw RemoteError.notFound }
                let item = try await registry.item(at: location)
                guard let name = Self.localName(item, at: location) else { throw RemoteError.notFound }
                let destination = directory.appending(path: name)
                try await download(location, item: item, to: destination, state: &state, progress: progress)
                items.append(destination)
            }
            return Staged(directory: directory, items: items)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// One item to `destination` (which must not exist): a file through `provider.fetch`, a folder created and
    /// filled item by item, so progress and cancellation work per file. Everything is written into a temporary
    /// folder on the destination's volume first and moved to `destination` only when complete, so a failure or
    /// cancellation partway leaves nothing at `destination`.
    public func download(_ location: RemoteLocation, item: RemoteItem, to destination: URL,
                         progress: @escaping @Sendable (Progress) -> Void) async throws {
        let fm = FileManager.default
        let scratch: URL
        if let replacement = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination,
                                         create: true) {
            scratch = replacement
        } else {   // a volume without a temporary-items folder: a hidden sibling
            scratch = destination.deletingLastPathComponent().appending(path: ".macx-partial-\(UUID().uuidString)",
                                                                         directoryHint: .isDirectory)
            try fm.createDirectory(at: scratch, withIntermediateDirectories: false)
        }
        defer { try? fm.removeItem(at: scratch) }
        let temp = scratch.appending(path: destination.lastPathComponent)
        var state = Progress()
        try await download(location, item: item, to: temp, state: &state, progress: progress)
        try Task.checkCancellation()
        try fm.moveItem(at: temp, to: destination)
    }

    private func download(_ location: RemoteLocation, item: RemoteItem, to destination: URL, state: inout Progress,
                          progress: @escaping @Sendable (Progress) -> Void) async throws {
        try Task.checkCancellation()
        guard let provider = registry.provider(id: location.provider) else { throw RemoteError.notFound }
        switch item.kind {
        case .directory:
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            try RemoteQuarantine.mark(destination, webURL: provider.webURL(location))
            var children: [RemoteItem] = []
            var seen: Set<String> = []
            for try await chunk in provider.list(location) {
                children += chunk.filter { RemoteItem.isValidName($0.name) && seen.insert($0.name).inserted }
            }
            for child in children {
                let target = destination.appending(path: child.name)
                // Belt and braces: a valid name is one component, so the target is always directly inside.
                guard target.deletingLastPathComponent().standardizedFileURL.path(percentEncoded: false).trimmingSuffix("/")
                        == destination.standardizedFileURL.path(percentEncoded: false).trimmingSuffix("/") else { continue }
                try await download(location.appending(child.name), item: child, to: target, state: &state, progress: progress)
            }
        case .submodule:
            return                                  // spec §8: submodules are not traversed
        case .file, .symlink:
            state.currentItem = item.name
            try await provider.fetch(location, item: item, to: destination)
            try RemoteQuarantine.mark(destination, webURL: provider.webURL(location))
            state.itemsDone += 1
            state.bytesDone += item.size ?? 0
            progress(state)
        @unknown default:
            throw RemoteError.unsupported
        }
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String { hasSuffix(suffix) ? String(dropLast(suffix.count)) : self }
}
