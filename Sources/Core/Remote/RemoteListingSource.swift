import Darwin
import Foundation
import MacxFS
import MacxPluginKit

/// Lists a remote folder through its provider as the `ReadEvent`s a `DirectoryReader` would produce, so FolderModel,
/// FolderWorker and every view work unchanged. Network work is async (never on lanes).
public struct RemoteListingSource: Sendable {
    let registry: ProviderRegistry
    let types: TypeRegistry

    public init(registry: ProviderRegistry, types: TypeRegistry) {
        self.registry = registry
        self.types = types
    }

    /// One `.batch` per provider chunk, then `.completed`; `.failed` for provider errors (mapped by `failure(for:)`).
    /// Cancelling iteration cancels the listing; a cancelled read just finishes.
    public func read(_ directory: URL, generation: Generation, options: ReadOptions) -> AsyncStream<ReadEvent> {
        let (stream, continuation) = AsyncStream<ReadEvent>.makeStream(bufferingPolicy: .unbounded)
        let registry = self.registry, types = self.types
        let task = Task {
            let started = ContinuousClock.now
            guard let location = RemoteLocation(url: directory), let provider = registry.provider(id: location.provider) else {
                continuation.yield(.failed(Self.failure(for: .notFound)))
                continuation.finish()
                return
            }
            var count = 0
            var seen: Set<String> = []
            do {
                for try await chunk in provider.list(location) {
                    if Task.isCancelled { break }
                    var batch = Batch(generation: generation)
                    for item in chunk where !options.directoriesOnly || item.kind == .directory {
                        // Trust boundary: a provider's names must be single, unique path components.
                        guard Self.isValidName(item.name), seen.insert(item.name).inserted else { continue }
                        let (entry, name) = Self.entry(for: item, fullPath: location.appending(item.name).url.absoluteString, types: types)
                        Array(name.utf8).withUnsafeBufferPointer { batch.append(entry, nameBytes: $0) }
                    }
                    count += batch.count
                    if batch.count > 0 { continuation.yield(.batch(batch)) }
                }
                if !Task.isCancelled {
                    continuation.yield(.completed(ReadSummary(entryCount: count, degradedCount: 0, usedFallback: false,
                                                              elapsed: ContinuousClock.now - started)))
                }
            } catch let error as RemoteError {
                if !Task.isCancelled { continuation.yield(.failed(Self.failure(for: error))) }
            } catch {
                if !Task.isCancelled { continuation.yield(.failed(Self.failure(for: .network(String(describing: error))))) }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// A name local readers could produce: non-empty, not "." or "..", no "/" or NUL.
    static func isValidName(_ name: String) -> Bool { RemoteItem.isValidName(name) }

    /// The watcher-patch path: re-lists the folder (providers cache listings) and keeps `names`.
    public func readItems(_ names: [String], in directory: URL, generation: Generation) async throws -> ItemReadResult {
        let wanted = Set(names)
        var batch = Batch(generation: generation)
        var found: Set<String> = []
        for await event in read(directory, generation: generation, options: ReadOptions()) {
            switch event {
            case .batch(let chunk):
                for i in 0..<chunk.count {
                    let name = chunk.name(at: i)
                    guard wanted.contains(name) else { continue }
                    found.insert(name)
                    Array(name.utf8).withUnsafeBufferPointer { batch.append(chunk.entries[i], nameBytes: $0) }
                }
            case .failed(let failure):
                throw failure
            default:
                break
            }
        }
        return ItemReadResult(batch: batch, missing: names.filter { !found.contains($0) }, errors: [:])
    }

    /// An `Entry` like SpotlightSearch's: identity is a hash of the item's full remote URL, flags from the item.
    /// Directories are always plain folders (a remote "X.app" is browsable); submodules are `.other` (not navigable).
    public static func entry(for item: RemoteItem, fullPath: String, types: TypeRegistry) -> (entry: Entry, name: String) {
        let name = item.name
        let ext = Substring((name as NSString).pathExtension)
        let kind: Kind
        let typeIndex: UInt16
        switch item.kind {
        case .directory: kind = .directory; typeIndex = TypeRegistry.folderIndex
        case .submodule: kind = .other; typeIndex = TypeRegistry.folderIndex
        case .file: kind = .file; typeIndex = types.index(forExtension: ext, isDirectory: false)
        case .symlink: kind = .symlink; typeIndex = types.index(forExtension: ext, isDirectory: false)
        @unknown default: kind = .other; typeIndex = types.index(forExtension: ext, isDirectory: false)   // a newer kit's kind
        }
        var flags: EntryFlags = [.readable]
        if name.hasPrefix(".") { flags.insert(.dotName) }
        if item.executable, kind == .file { flags.insert(.executable) }
        let size = (kind == .file || kind == .symlink) ? max(0, item.size ?? 0) : 0   // untrusted: no negative sizes
        let mtime = item.modified.map { nanoseconds(since1970: $0) } ?? 0
        let id = SpotlightSearch.fnv1a(fullPath)
        let entry = Entry(rowID: id, fileID: id, size: size, allocSize: size, mtime: mtime, ctime: mtime, nameOffset: 0,
                          nameLen: UInt16(min(name.utf8.count, Int(UInt16.max))), kind: kind, flags: flags, typeIndex: typeIndex)
        return (entry, name)
    }

    /// A provider's date as ns since 1970, or 0 (unknown) when it is NaN, infinite or outside Int64's range
    /// (about 1678...2262, e.g. `Date.distantFuture`). `Int64(_: Double)` would trap on those.
    static func nanoseconds(since1970 date: Date) -> Int64 {
        Int64(exactly: (date.timeIntervalSince1970 * 1e9).rounded()) ?? 0
    }

    public static func failure(for error: RemoteError) -> ReadFailure {
        switch error {
        case .notFound: ReadFailure(code: ENOENT, stage: .open)
        case .noAccess: ReadFailure(code: EACCES, stage: .open)
        case .rateLimited(let resetAt): ReadFailure(code: EAGAIN, stage: .open, resetAt: resetAt)
        case .network: ReadFailure(code: ETIMEDOUT, stage: .unresponsiveVolume)
        case .unsupported: ReadFailure(code: ENOTSUP, stage: .open)
        @unknown default: ReadFailure(code: ENOTSUP, stage: .open)   // a newer kit's error
        }
    }
}
