import Foundation
import Core
import MacxPluginKit

/// REPOSITORIES rows (spec §4.6): the roots of recent repositories and of remote favorites, one row per repository,
/// grouped by provider (registry order: built-ins first), then by repository name. Unknown providers are skipped.
enum RepositoryRows {
    static func rows(recent: [String], favorites: [Favorite], registry: ProviderRegistry) -> [URL] {
        let order = Dictionary(registry.providers.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var roots: [(order: Int, location: RemoteLocation)] = []
        for string in recent + favorites.compactMap(\.remoteURL) {
            guard let url = URL(string: string), let l = RemoteLocation(url: url), let index = order[l.provider] else { continue }
            let root = RemoteLocation(provider: l.provider, repo: l.repo)
            if seen.insert(root.url.absoluteString).inserted { roots.append((index, root)) }
        }
        return roots.sorted {
            ($0.order, $0.location.repo.lowercased(), $0.location.repo) < ($1.order, $1.location.repo.lowercased(), $1.location.repo)
        }.map(\.location.url)
    }
}
