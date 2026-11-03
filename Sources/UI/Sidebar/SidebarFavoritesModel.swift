import Darwin
import Foundation
import Core
import MacxFS

/// The FAVORITES section (§5.4): the visible defaults (Home, Desktop, Documents, Downloads, Applications; only those
/// that exist) followed by the user's bookmarks, resolved on lanes (`FavoritesResolver`). Edits go to `Settings`:
/// add (folders only, no duplicates), reorder, remove (a default is hidden, a bookmark removed; never a file-system
/// call), and Locate… for stale bookmarks.
@MainActor
final class SidebarFavoritesModel {
    private(set) var rows: [SidebarFavorite] = []
    var onChange: (() -> Void)?

    private let environment: CoreEnvironment
    private let confinement: SandboxConfinement
    private var settings: Settings { environment.settings }
    private var generation = 0
    private var refreshTask: Task<Void, Never>?

    /// `confinement`: in sandbox mode rows outside the root (Applications, old bookmarks) are left out.
    init(environment: CoreEnvironment, confinement: SandboxConfinement = SandboxConfinement(root: nil)) {
        self.environment = environment
        self.confinement = confinement
    }

    // MARK: defaults

    /// Stable ids for the defaults, so a default row keeps its outline identity and commands can tell it apart.
    static func defaultID(_ kind: DefaultFavorite) -> UUID {
        let index = DefaultFavorite.allCases.firstIndex(of: kind) ?? 0
        return UUID(uuidString: String(format: "6D616378-0000-4000-8000-%012d", index + 1))!
    }

    static func defaultKind(for id: UUID) -> DefaultFavorite? {
        DefaultFavorite.allCases.first { defaultID($0) == id }
    }

    static func defaultName(_ kind: DefaultFavorite) -> String {
        switch kind {
        case .home: L10n.string("Home")
        case .desktop: L10n.string("Desktop")
        case .documents: L10n.string("Documents")
        case .downloads: L10n.string("Downloads")
        case .applications: L10n.string("Applications")
        }
    }

    // MARK: resolution

    /// Re-resolves everything (settings or volumes changed). A newer refresh supersedes an older one.
    func refresh() {
        generation += 1
        let current = generation
        let kinds = DefaultFavorite.allCases.filter { !settings.hiddenDefaultFavorites.contains($0) }
        let home = settings.home
        let confinement = self.confinement
        let defaults = kinds.map { kind in
            (kind, FavoritesResolver.defaultFavoriteURL(kind, home: home))
        }.filter { confinement.allows($0.1) }
        let favorites = settings.favorites
        let lanes = environment.lanes, volumes = environment.volumes
        let lanesForDefaults = defaults.map { volumes.volume(for: $0.1)?.id ?? .unknown }
        let mountTable = volumes.mountTable
        refreshTask = Task { @MainActor in
            var rows: [SidebarFavorite] = []
            for ((kind, url), volume) in zip(defaults, lanesForDefaults) where await Self.isDirectory(url, lanes: lanes, volume: volume) {
                let favorite = Favorite(id: Self.defaultID(kind), bookmark: Data(), displayName: Self.defaultName(kind),
                                        lastKnownPath: url.path(percentEncoded: false))
                rows.append(SidebarFavorite(resolved: ResolvedFavorite(favorite: favorite, url: url, isStale: false), defaultKind: kind))
            }
            let resolved = await FavoritesResolver.resolve(favorites, lanes: lanes, mountTable: mountTable)
            guard current == self.generation else { return }
            rows += resolved.filter { confinement.allows(Self.location(of: $0)) }.map { SidebarFavorite(resolved: $0, defaultKind: nil) }
            self.persistRefreshedBookmarks(resolved)
            if rows != self.rows {
                self.rows = rows
                self.onChange?()
            }
        }
    }

    /// Where a bookmark points (its last known path when stale).
    private static func location(of favorite: ResolvedFavorite) -> URL {
        favorite.url ?? URL(filePath: favorite.favorite.lastKnownPath, directoryHint: .isDirectory)
    }

    /// Tests: waits for the latest refresh.
    func settled() async {
        while let task = refreshTask {
            await task.value
            if task == refreshTask { return }
        }
    }

    /// The system reported a bookmark as out of date or moved: store the refreshed data (same id and name).
    private func persistRefreshedBookmarks(_ resolved: [ResolvedFavorite]) {
        var favorites = settings.favorites
        var changed = false
        for r in resolved where !r.isStale && r.url != nil {
            guard let i = favorites.firstIndex(where: { $0.id == r.favorite.id }),
                  favorites[i].bookmark != r.favorite.bookmark || favorites[i].lastKnownPath != r.favorite.lastKnownPath
            else { continue }
            favorites[i].bookmark = r.favorite.bookmark
            favorites[i].lastKnownPath = r.favorite.lastKnownPath
            changed = true
        }
        if changed { settings.favorites = favorites }
    }

    // MARK: edits

    /// Removes the row from the sidebar. Never touches the target.
    func remove(id: UUID) { Self.remove(id: id, from: settings) }

    /// Remove from Favorites (also the interim command handler's): a default is hidden, a bookmark dropped.
    static func remove(id: UUID, from settings: Settings) {
        if let kind = defaultKind(for: id) {
            settings.hiddenDefaultFavorites.insert(kind)
        } else {
            settings.favorites.removeAll { $0.id == id }
        }
    }

    /// Moves a user favorite to `index` among the user favorites (counted after the removal). false = not a bookmark.
    @discardableResult
    func move(id: UUID, toUserIndex index: Int) -> Bool {
        var favorites = settings.favorites
        guard let from = favorites.firstIndex(where: { $0.id == id }) else { return false }
        let favorite = favorites.remove(at: from)
        favorites.insert(favorite, at: max(0, min(index, favorites.count)))
        if favorites != settings.favorites { settings.favorites = favorites }
        return true
    }

    /// Adds the folders among `urls` at `index` among the user favorites, skipping files and folders already listed.
    /// Returns how many were added.
    @discardableResult
    func add(_ urls: [URL], atUserIndex index: Int) async -> Int {
        let lanes = environment.lanes
        var made: [Favorite] = []
        var seen = Set(rows.compactMap { $0.url.map(ChangeBus.key(for:)) } + settings.favorites.map(\.lastKnownPath).map {
            ChangeBus.key(for: URL(filePath: $0, directoryHint: .isDirectory))
        })
        for url in urls where url.isFileURL {
            let key = ChangeBus.key(for: url)
            guard !seen.contains(key) else { continue }
            let volume = environment.volumes.volume(for: url)?.id ?? .unknown
            guard await Self.isDirectory(url, lanes: lanes, volume: volume),
                  let favorite = try? await FavoritesResolver.makeFavorite(for: url, lanes: lanes) else { continue }
            seen.insert(key)
            made.append(favorite)
        }
        guard !made.isEmpty else { return 0 }
        var favorites = settings.favorites
        favorites.insert(contentsOf: made, at: max(0, min(index, favorites.count)))
        settings.favorites = favorites
        return made.count
    }

    /// Locate…: points a (stale) bookmark at `url`, keeping its id and position. false = not a folder or not a bookmark.
    @discardableResult
    func relocate(id: UUID, to url: URL) async -> Bool {
        let lanes = environment.lanes
        let volume = environment.volumes.volume(for: url)?.id ?? .unknown
        guard settings.favorites.contains(where: { $0.id == id }),
              await Self.isDirectory(url, lanes: lanes, volume: volume),
              let made = try? await FavoritesResolver.makeFavorite(for: url, lanes: lanes),
              let index = settings.favorites.firstIndex(where: { $0.id == id }) else { return false }
        var favorites = settings.favorites
        favorites[index].bookmark = made.bookmark
        favorites[index].lastKnownPath = made.lastKnownPath
        favorites[index].displayName = made.displayName
        settings.favorites = favorites
        return true
    }

    /// `stat` (following links) on a lane of the folder's volume. Lane failures count as "not a folder".
    private static func isDirectory(_ url: URL, lanes: LanePool, volume: VolumeID) async -> Bool {
        let path = url.path(percentEncoded: false)
        return (try? await lanes.perform(on: volume, .read) { _ in
            var info = stat()
            return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
        }) ?? false
    }
}
