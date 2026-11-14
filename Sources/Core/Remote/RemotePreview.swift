import Darwin
import Foundation
import MacxFS
import MacxPluginKit

/// What the preview pane, Quick Look and Open do with one remote item (spec §4.3–4.4).
public enum RemotePreviewDecision: Sendable, Equatable {
    case folder
    /// The cached, read-only local copy (immutable per content id).
    case local(URL)
    /// Larger than the auto-preview limit: the pane offers "Download to preview (<size>)".
    case needsDownload(size: Int64)
    /// errno, as `PreviewContent.unavailable` takes it (ENOENT, EACCES, EAGAIN rate limit, ETIMEDOUT network).
    case failed(code: Int32)
}

public enum RemotePreview {
    /// Most symlinks followed before giving up with ELOOP.
    public static let maxLinkHops = 8

    /// `force`: the user asked (the button, Quick Look, Open), so no size limit. A remote symlink is followed inside
    /// its repository (same ref) to the item it points to; a target outside the repository fails with ENOENT.
    public static func prepare(_ url: URL, registry: ProviderRegistry, cache: RemoteFileCache, force: Bool,
                               limit: Int64 = RemoteFileCache.autoPreviewLimit) async -> RemotePreviewDecision {
        guard var location = RemoteLocation(url: url), let provider = registry.provider(id: location.provider) else {
            return .failed(code: ENOENT)
        }
        var item: RemoteItem
        do { item = try await registry.item(at: location) } catch { return .failed(code: RemoteListingSource.failure(for: error).code) }
        var hops = 0
        while item.kind == .symlink {
            hops += 1
            guard hops <= maxLinkHops else { return .failed(code: ELOOP) }
            let target: String
            do { target = try await linkTarget(location, item: item, provider: provider, cache: cache) }
            catch { return .failed(code: RemoteListingSource.failure(for: error).code) }
            guard let next = resolve(target, from: location, absoluteFromRoot: false) else { return .failed(code: ENOENT) }
            do { item = try await registry.item(at: next) } catch { return .failed(code: RemoteListingSource.failure(for: error).code) }
            location = next
        }
        switch item.kind {
        case .directory, .submodule: return .folder
        case .file: break
        case .symlink: return .failed(code: ELOOP)          // not reached: the loop above follows every link
        @unknown default: return .failed(code: ENOTSUP)   // a newer kit's kind: nothing to preview
        }
        let size = item.size ?? 0
        if !force, size > limit { return .needsDownload(size: size) }
        if Task.isCancelled { return .failed(code: ECANCELED) }
        do {
            return .local(try await cache.localURL(for: location, item: item, provider: provider))
        } catch {
            return .failed(code: RemoteListingSource.failure(for: error).code)
        }
    }

    /// `relative` (a symlink's target, a Markdown link's path) from the folder holding `file`, inside the same
    /// repository and ref. "." and ".." are resolved; nil when it climbs above the repository root, or when it is
    /// absolute and `absoluteFromRoot` is false (a symlink's absolute target is outside the repository). With
    /// `absoluteFromRoot` (Markdown, as on the web), "/a/b" starts at the repository root.
    public static func resolve(_ relative: String, from file: RemoteLocation, absoluteFromRoot: Bool) -> RemoteLocation? {
        let absolute = relative.hasPrefix("/")
        guard !relative.isEmpty, !absolute || absoluteFromRoot else { return nil }
        var parts = absolute ? [] : Array(file.path.dropLast())
        for component in relative.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..":
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            default: parts.append(String(component))
            }
        }
        return RemoteLocation(provider: file.provider, repo: file.repo, ref: file.ref, path: parts)
    }

    /// The URL form of `resolve(_:from:absoluteFromRoot: true)` for a remote Markdown file's relative links.
    public static func linkURL(_ relative: String, relativeTo file: URL) -> URL? {
        RemoteLocation(url: file).flatMap { resolve(relative, from: $0, absoluteFromRoot: true) }?.url
    }

    /// A symlink's target path: the provider writes the link (or, for a provider that cannot, a file holding the
    /// target) into a scratch file under the cache's `.partial` folder, removed again here.
    static func linkTarget(_ location: RemoteLocation, item: RemoteItem, provider: any RemoteProvider,
                           cache: RemoteFileCache) async throws(RemoteError) -> String {
        let fm = FileManager.default
        let partials = cache.root.appending(path: ".partial", directoryHint: .isDirectory)
        do { try fm.createDirectory(at: partials, withIntermediateDirectories: true) }
        catch { throw .network(error.localizedDescription) }
        let scratch = partials.appending(path: UUID().uuidString, directoryHint: .notDirectory)
        defer { try? fm.removeItem(at: scratch) }
        try await provider.fetch(location, item: item, to: scratch)
        let path = scratch.path(percentEncoded: false)
        if let target = try? fm.destinationOfSymbolicLink(atPath: path) { return target }
        guard let data = fm.contents(atPath: path), data.count <= 4096 else { throw .unsupported }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    /// Open, Open With and Quick Look: each remote URL is replaced by its local copy (downloaded now, no limit);
    /// file URLs pass through unchanged. Order is kept; `failed` lists remote URLs that could not be fetched (once the
    /// calling task is cancelled, every remaining remote URL, with no download started).
    public static func localCopies(_ urls: [URL], registry: ProviderRegistry,
                                   cache: RemoteFileCache) async -> (local: [URL], failed: [URL]) {
        var local: [URL] = [], failed: [URL] = []
        for url in urls {
            guard RemoteScheme.isRemote(url) else { local.append(url); continue }
            // Quick Look moved on (or Open was abandoned): start no further downloads.
            if Task.isCancelled { failed.append(url); continue }
            if case .local(let copy) = await prepare(url, registry: registry, cache: cache, force: true) {
                local.append(copy)
            } else {
                failed.append(url)
            }
        }
        return (local, failed)
    }
}
