import Foundation
import MacxFS

public struct Favorite: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var bookmark: Data
    public var displayName: String
    public var lastKnownPath: String
    public init(id: UUID = UUID(), bookmark: Data, displayName: String, lastKnownPath: String) {
        self.id = id
        self.bookmark = bookmark
        self.displayName = displayName
        self.lastKnownPath = lastKnownPath
    }
}

/// `url == nil && isStale`: the bookmark no longer resolves (shown dimmed with "Locate…").
/// `url == nil && !isStale`: resolution could not run (the lane failed or the volume is unresponsive).
/// When resolution succeeds, `favorite` carries a refreshed bookmark and `lastKnownPath` if the system reported
/// the bookmark data as out of date (callers may persist it); `id` and `displayName` never change.
public struct ResolvedFavorite: Sendable, Hashable {
    public var favorite: Favorite
    public var url: URL?
    public var isStale: Bool
    public init(favorite: Favorite, url: URL?, isStale: Bool) {
        self.favorite = favorite
        self.url = url
        self.isStale = isStale
    }
}

/// Each bookmark resolves in its own LanePool.perform on VolumeID.unknown, so one hung network bookmark
/// poisons only its lane and the others still resolve.
public enum FavoritesResolver {
    public static func makeFavorite(for url: URL, lanes: LanePool) async throws -> Favorite {
        try await lanes.perform(on: .unknown, .read) { _ in
            let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            let values = try? url.resourceValues(forKeys: [.localizedNameKey])
            let name = values?.localizedName ?? url.lastPathComponent
            return Favorite(bookmark: bookmark, displayName: name, lastKnownPath: plainPath(url))
        }
    }

    public static func resolve(_ favorites: [Favorite], lanes: LanePool) async -> [ResolvedFavorite] {
        await withTaskGroup(of: (Int, ResolvedFavorite).self) { group in
            for (index, favorite) in favorites.enumerated() {
                group.addTask {
                    do {
                        return (index, try await lanes.perform(on: .unknown, .read) { _ in resolveNow(favorite) })
                    } catch {
                        return (index, ResolvedFavorite(favorite: favorite, url: nil, isStale: false))
                    }
                }
            }
            var results = [ResolvedFavorite?](repeating: nil, count: favorites.count)
            for await (index, resolved) in group { results[index] = resolved }
            return results.compactMap { $0 }
        }
    }

    public static func defaultFavoriteURL(_ f: DefaultFavorite, home: URL) -> URL {
        switch f {
        case .home: home
        case .desktop: home.appending(path: "Desktop", directoryHint: .isDirectory)
        case .documents: home.appending(path: "Documents", directoryHint: .isDirectory)
        case .downloads: home.appending(path: "Downloads", directoryHint: .isDirectory)
        case .applications: URL(filePath: "/Applications", directoryHint: .isDirectory)
        }
    }

    /// Standardized path without a trailing slash ("/" stays "/").
    static func plainPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// Runs on a lane thread. Never shows UI and never mounts a volume.
    private static func resolveNow(_ favorite: Favorite) -> ResolvedFavorite {
        var outOfDate = false
        guard let url = try? URL(resolvingBookmarkData: favorite.bookmark, options: [.withoutUI, .withoutMounting],
                                 relativeTo: nil, bookmarkDataIsStale: &outOfDate) else {
            return ResolvedFavorite(favorite: favorite, url: nil, isStale: true)
        }
        var info = stat()
        guard lstat(url.path(percentEncoded: false), &info) == 0 else {
            return ResolvedFavorite(favorite: favorite, url: nil, isStale: true)
        }
        var updated = favorite
        let path = plainPath(url)
        if outOfDate || path != favorite.lastKnownPath {
            updated.lastKnownPath = path
            if outOfDate, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                updated.bookmark = fresh
            }
        }
        return ResolvedFavorite(favorite: updated, url: url, isStale: false)
    }
}
