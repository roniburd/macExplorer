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
    /// `force`: the user asked (the button, Quick Look, Open), so no size limit.
    public static func prepare(_ url: URL, registry: ProviderRegistry, cache: RemoteFileCache, force: Bool,
                               limit: Int64 = RemoteFileCache.autoPreviewLimit) async -> RemotePreviewDecision {
        guard let location = RemoteLocation(url: url), let provider = registry.provider(id: location.provider) else {
            return .failed(code: ENOENT)
        }
        let item: RemoteItem
        do { item = try await registry.item(at: location) } catch { return .failed(code: RemoteListingSource.failure(for: error).code) }
        switch item.kind {
        case .directory, .submodule: return .folder
        case .file, .symlink: break
        @unknown default: return .failed(code: ENOTSUP)   // a newer kit's kind: nothing to preview
        }
        let size = item.size ?? 0
        if !force, size > limit { return .needsDownload(size: size) }
        do {
            return .local(try await cache.localURL(for: location, item: item, provider: provider))
        } catch {
            return .failed(code: RemoteListingSource.failure(for: error).code)
        }
    }

    /// Open, Open With and Quick Look: each remote URL is replaced by its local copy (downloaded now, no limit);
    /// file URLs pass through unchanged. Order is kept; `failed` lists remote URLs that could not be fetched.
    public static func localCopies(_ urls: [URL], registry: ProviderRegistry,
                                   cache: RemoteFileCache) async -> (local: [URL], failed: [URL]) {
        var local: [URL] = [], failed: [URL] = []
        for url in urls {
            guard RemoteScheme.isRemote(url) else { local.append(url); continue }
            if case .local(let copy) = await prepare(url, registry: registry, cache: cache, force: true) {
                local.append(copy)
            } else {
                failed.append(url)
            }
        }
        return (local, failed)
    }
}
