import Foundation
import MacxPluginKit
import Synchronization

/// What the provider has learned, per repository (spec §3: one recursive tree per repo + commit). Synchronous, so
/// `invalidate` takes effect before the refresh that follows it re-lists.
final class TreeCache: Sendable {
    struct Tree: Sendable {
        /// Folder path ("" = root) → its items. Complete for a recursive tree; filled folder by folder when truncated.
        var folders: [String: [RemoteItem]] = [:]
        /// Folder path → its tree SHA (the truncated fallback lists a folder by it).
        var treeSHAs: [String: String] = [:]
        var complete: Bool
    }

    private struct State {
        var defaultBranches: [String: String] = [:]   // repo → branch
        var commits: [String: String] = [:]           // repo \0 ref → commit
        var refs: [String: [RemoteRef]] = [:]         // repo → refs
        var trees: [String: Tree] = [:]               // repo \0 commit → tree
        var kinds: [String: RemoteItemKind] = [:]     // repo \0 ref \0 path → kind (webURL blob vs tree)
    }

    private let state = Mutex(State())

    static func key(_ parts: String...) -> String { parts.joined(separator: "\u{0}") }

    func defaultBranch(_ repo: String) -> String? { state.withLock { $0.defaultBranches[repo] } }
    func setDefaultBranch(_ branch: String, _ repo: String) { state.withLock { $0.defaultBranches[repo] = branch } }
    func commit(_ repo: String, _ ref: String) -> String? { state.withLock { $0.commits[Self.key(repo, ref)] } }
    func setCommit(_ commit: String, _ repo: String, _ ref: String) {
        state.withLock { $0.commits[Self.key(repo, ref)] = commit }
    }
    func refs(_ repo: String) -> [RemoteRef]? { state.withLock { $0.refs[repo] } }
    func setRefs(_ refs: [RemoteRef], _ repo: String) { state.withLock { $0.refs[repo] = refs } }
    func tree(_ repo: String, _ commit: String) -> Tree? { state.withLock { $0.trees[Self.key(repo, commit)] } }
    func setTree(_ tree: Tree, _ repo: String, _ commit: String) {
        state.withLock { $0.trees[Self.key(repo, commit)] = tree }
    }
    func addFolder(_ path: String, items: [RemoteItem], childSHAs: [String: String], _ repo: String, _ commit: String) {
        state.withLock {
            let key = Self.key(repo, commit)
            $0.trees[key, default: Tree(complete: false)].folders[path] = items
            $0.trees[key]?.treeSHAs.merge(childSHAs) { _, new in new }
        }
    }
    func recordKinds(_ items: [RemoteItem], in location: RemoteLocation) {
        state.withLock {
            for item in items {
                $0.kinds[Self.key(location.repo, location.ref ?? "", location.appending(item.name).pathString)] = item.kind
            }
        }
    }
    func kind(of location: RemoteLocation) -> RemoteItemKind? {
        state.withLock { $0.kinds[Self.key(location.repo, location.ref ?? "", location.pathString)] }
    }

    /// Refresh (spec §4.1): forget the ref's commit (or every ref of the repo when nil), its trees, and the refs list.
    func invalidate(repo: String, ref: String?) {
        state.withLock { s in
            let prefix = repo + "\u{0}"
            let refKeys = s.commits.keys.filter { $0.hasPrefix(prefix) && (ref == nil || $0 == Self.key(repo, ref!)) }
            for key in refKeys {
                if let commit = s.commits.removeValue(forKey: key) { s.trees[Self.key(repo, commit)] = nil }
            }
            s.refs[repo] = nil
            if ref == nil { s.defaultBranches[repo] = nil }
        }
    }

    /// The recursive response as folders: every entry under its parent, every tree a (possibly empty) folder.
    static func build(_ entries: [GitHubClient.TreeEntry], complete: Bool) -> Tree {
        var tree = Tree(folders: ["": []], complete: complete)
        for entry in entries {
            let (parent, name) = splitPath(entry.path)
            tree.folders[parent, default: []].append(item(for: entry, name: name))
            if entry.type == "tree" {
                if tree.folders[entry.path] == nil { tree.folders[entry.path] = [] }
                tree.treeSHAs[entry.path] = entry.sha
            }
        }
        if !complete {   // a truncated listing is only trusted for the root's direct children it names
            tree.folders = ["": tree.folders[""] ?? []]
        }
        return tree
    }

    static func item(for entry: GitHubClient.TreeEntry, name: String) -> RemoteItem {
        let kind: RemoteItemKind = switch entry.type {
        case "tree": .directory
        case "commit": .submodule
        default: entry.mode == "120000" ? .symlink : .file
        }
        return RemoteItem(name: name, kind: kind, size: kind == .file || kind == .symlink ? entry.size : nil,
                          executable: entry.mode == "100755", contentID: entry.sha, modified: nil)
    }

    static func splitPath(_ path: String) -> (parent: String, name: String) {
        guard let slash = path.lastIndex(of: "/") else { return ("", path) }
        return (String(path[..<slash]), String(path[path.index(after: slash)...]))
    }
}
