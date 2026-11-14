import Foundation
import MacxPluginKit

/// Copy out of a repository (spec §4.5): downloads remote items into one fresh staging folder (folders recursively,
/// listing through the provider), so a normal copy job can then put them where the user pasted or dropped them.
/// Throws `RemoteError` or `CancellationError`; on any error the staging folder is removed.
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

    public func stage(_ urls: [URL], progress: @escaping @Sendable (Progress) -> Void) async throws -> Staged {
        let directory = stagingRoot.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            var state = Progress()
            var items: [URL] = []
            for url in urls {
                guard let location = RemoteLocation(url: url) else { throw RemoteError.notFound }
                let item = try await registry.item(at: location)
                let destination = directory.appending(path: item.name)
                try await download(location, item: item, to: destination, state: &state, progress: progress)
                items.append(destination)
            }
            return Staged(directory: directory, items: items)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// One item to `destination` (which must not exist): a file through `provider.fetch`, a folder created here and
    /// filled item by item, so progress and cancellation work per file.
    public func download(_ location: RemoteLocation, item: RemoteItem, to destination: URL,
                         progress: @escaping @Sendable (Progress) -> Void) async throws {
        var state = Progress()
        try await download(location, item: item, to: destination, state: &state, progress: progress)
    }

    private func download(_ location: RemoteLocation, item: RemoteItem, to destination: URL, state: inout Progress,
                          progress: @escaping @Sendable (Progress) -> Void) async throws {
        try Task.checkCancellation()
        guard let provider = registry.provider(id: location.provider) else { throw RemoteError.notFound }
        switch item.kind {
        case .directory:
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            var children: [RemoteItem] = []
            for try await chunk in provider.list(location) { children += chunk }
            for child in children {
                try await download(location.appending(child.name), item: child, to: destination.appending(path: child.name),
                                   state: &state, progress: progress)
            }
        case .submodule:
            return                                  // spec §8: submodules are not traversed
        case .file, .symlink:
            state.currentItem = item.name
            try await provider.fetch(location, item: item, to: destination)
            state.itemsDone += 1
            state.bytesDone += item.size ?? 0
            progress(state)
        @unknown default:
            throw RemoteError.unsupported
        }
    }
}
