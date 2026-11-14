import Foundation
import MacxPluginKit

/// The built-in GitHub provider (spec §3): public repositories, anonymous, read-only.
public final class GitHubProvider: RemoteProvider, Sendable {
    public let id = GitHubAddress.providerID
    public let displayName = "GitHub"
    public let iconSymbol = "chevron.left.forwardslash.chevron.right"

    let client: GitHubClient
    let cache = TreeCache()

    public convenience init(session: URLSession = GitHubProvider.makeSession(), appVersion: String) {
        self.init(transport: { request in try await session.data(for: request) }, appVersion: appVersion)
    }

    init(transport: @escaping GitHubClient.Transport, appVersion: String) {
        client = GitHubClient(transport: transport, userAgent: "macExplorer/\(appVersion)")
    }

    /// Ephemeral (no cookies, no disk cache), 30 s per request.
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }

    // MARK: addresses

    public func parseAddress(_ text: String) -> RemoteLocation? { GitHubAddress.parse(text) }

    /// "gh:" while typing it; `gh:o/r@<ref>` for refs already listed for that repo.
    public func completions(for text: String) async -> [String] {
        let lower = text.lowercased()
        if !lower.isEmpty, "gh:".hasPrefix(lower), lower != "gh:" { return ["gh:"] }
        guard lower.hasPrefix("gh:"), let at = text.firstIndex(of: "@"),
              let location = GitHubAddress.parse(String(text[..<at])), let refs = cache.refs(location.repo) else {
            return []
        }
        let typed = String(text[text.index(after: at)...])
        let head = String(text[...at])
        return refs.map(\.name).filter { $0.lowercased().hasPrefix(typed.lowercased()) && $0 != typed }.map { head + $0 }
    }

    public func displayRoot(_ location: RemoteLocation) -> String { GitHubWeb.displayRoot(location) }

    public func webURL(_ location: RemoteLocation) -> URL? {
        let kind = cache.kind(of: location)
        return GitHubWeb.webURL(location, isFile: kind == .file || kind == .symlink)
    }

    // MARK: refs

    public func listRefs(repo: String) async throws(RemoteError) -> [RemoteRef] {
        if let cached = cache.refs(repo) { return cached }
        let branches = try await client.refs(repo, kind: "branches")
        let tags = try await client.refs(repo, kind: "tags")
        let refs = branches.map { RemoteRef(name: $0.name, kind: .branch, commit: $0.commit.sha) }
            + tags.map { RemoteRef(name: $0.name, kind: .tag, commit: $0.commit.sha) }
        cache.setRefs(refs, repo)
        return refs
    }

    /// nil → the default branch. A ref with "/" is split against the refs (GitHubAddress.split): what is left over goes
    /// in front of `path`. A ref without "/" is kept as is (a branch, tag or SHA; a wrong one fails when listed).
    public func resolveRef(_ location: RemoteLocation) async throws(RemoteError) -> RemoteLocation {
        guard let ref = location.ref else {
            return location.withRef(try await defaultBranch(location.repo))
        }
        guard ref.contains("/") else { return location }
        let known = Set(try await listRefs(repo: location.repo).map(\.name))
        let (name, extra) = GitHubAddress.split(ref, knownRefs: known)
        var resolved = location.withRef(name)
        resolved.path = extra + location.path
        return resolved
    }

    // MARK: listing

    public func list(_ location: RemoteLocation) -> AsyncThrowingStream<[RemoteItem], any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(try await self.items(in: location))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func items(in location: RemoteLocation) async throws(RemoteError) -> [RemoteItem] {
        let resolved = try await resolveRef(location)
        let commit = try await commit(for: resolved)
        let items = try await folder(resolved.pathString, repo: resolved.repo, commit: commit)
        cache.recordKinds(items, in: resolved)
        return items
    }

    func defaultBranch(_ repo: String) async throws(RemoteError) -> String {
        if let cached = cache.defaultBranch(repo) { return cached }
        let branch = try await client.defaultBranch(repo)
        cache.setDefaultBranch(branch, repo)
        return branch
    }

    func commit(for location: RemoteLocation) async throws(RemoteError) -> String {
        let ref = location.ref ?? ""
        if let cached = cache.commit(location.repo, ref) { return cached }
        let commit = try await client.commit(location.repo, ref: ref)
        cache.setCommit(commit, location.repo, ref)
        return commit
    }

    /// One folder's items: from the recursive tree (fetched once per commit), or for a truncated tree by walking down
    /// from the root one non-recursive request per folder not seen yet.
    func folder(_ path: String, repo: String, commit: String) async throws(RemoteError) -> [RemoteItem] {
        if cache.tree(repo, commit) == nil {
            let response = try await client.tree(repo, sha: commit, recursive: true)
            cache.setTree(TreeCache.build(response.tree, complete: response.truncated != true), repo, commit)
        }
        guard let tree = cache.tree(repo, commit) else { throw .notFound }
        if let items = tree.folders[path], tree.complete || path != "" || !tree.treeSHAs.isEmpty { return items }
        if tree.complete { throw .notFound }
        return try await walk(to: path, repo: repo, commit: commit)
    }

    private func walk(to path: String, repo: String, commit: String) async throws(RemoteError) -> [RemoteItem] {
        let parts = path.split(separator: "/").map(String.init)
        var current = ""
        var sha = commit
        try await load(current, sha: sha, repo: repo, commit: commit)
        for part in parts {
            let next = current.isEmpty ? part : current + "/" + part
            guard let tree = cache.tree(repo, commit),
                  tree.folders[current]?.contains(where: { $0.name == part && $0.kind == .directory }) == true,
                  let childSHA = tree.treeSHAs[next] else { throw .notFound }
            sha = childSHA
            current = next
            try await load(current, sha: sha, repo: repo, commit: commit)
        }
        return cache.tree(repo, commit)?.folders[current] ?? []
    }

    private func load(_ path: String, sha: String, repo: String, commit: String) async throws(RemoteError) {
        if let tree = cache.tree(repo, commit), tree.folders[path] != nil, path != "" || !tree.treeSHAs.isEmpty { return }
        let response = try await client.tree(repo, sha: sha, recursive: false)
        let items = response.tree.map { TreeCache.item(for: $0, name: $0.path) }
        var childSHAs: [String: String] = [:]
        for entry in response.tree where entry.type == "tree" {
            childSHAs[path.isEmpty ? entry.path : path + "/" + entry.path] = entry.sha
        }
        cache.addFolder(path, items: items, childSHAs: childSHAs, repo, commit)
    }

    // MARK: fetch

    /// A file's bytes; a symlink as a link to its target; a folder recursively (submodules skipped). The destination
    /// must not exist. Executable files get 0755.
    public func fetch(_ location: RemoteLocation, item: RemoteItem, to destination: URL) async throws(RemoteError) {
        let resolved = try await resolveRef(location)
        let commit = try await commit(for: resolved)
        try await fetch(resolved, item: item, commit: commit, to: destination)
    }

    private func fetch(_ location: RemoteLocation, item: RemoteItem, commit: String, to destination: URL)
        async throws(RemoteError) {
        let fm = FileManager.default
        do {
            switch item.kind {
            case .submodule:
                throw RemoteError.unsupported
            case .file:
                let data = try await client.raw(location.repo, commit: commit, path: location.pathString)
                try data.write(to: destination, options: .withoutOverwriting)
                if item.executable {
                    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path(percentEncoded: false))
                }
            case .symlink:
                let target = String(decoding: try await client.raw(location.repo, commit: commit, path: location.pathString),
                                    as: UTF8.self)
                try fm.createSymbolicLink(atPath: destination.path(percentEncoded: false), withDestinationPath: target)
            case .directory:
                try fm.createDirectory(at: destination, withIntermediateDirectories: false)
                for child in try await folder(location.pathString, repo: location.repo, commit: commit)
                    where child.kind != .submodule {
                    try await fetch(location.appending(child.name), item: child, commit: commit,
                                    to: destination.appending(path: child.name,
                                                              directoryHint: child.kind == .directory ? .isDirectory : .notDirectory))
                }
            @unknown default:
                throw RemoteError.unsupported
            }
        } catch let error as RemoteError {
            throw error
        } catch {
            throw .network(error.localizedDescription)
        }
    }

    public func invalidate(repo: String, ref: String?) { cache.invalidate(repo: repo, ref: ref) }
}
