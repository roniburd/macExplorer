import Foundation
import MacxPluginKit
import Synchronization

/// What the provider has learned, per repository (spec §3: one recursive tree per repo + commit). Synchronous, so
/// `invalidate` takes effect before the refresh that follows it re-lists. Trees are bounded: past `maxTrees` trees or
/// `maxItems` items in all, the least recently used trees are dropped (and fetched again when next listed); the one
/// just stored or read is never dropped.
final class TreeCache: Sendable {
    struct Tree: Sendable {
        /// Folder path ("" = root) → its items. Complete for a recursive tree; for a truncated one it starts empty and
        /// holds only folders the fallback listed itself, so a present key always means a full listing.
        var folders: [String: [RemoteItem]] = [:]
        /// Folder path → its tree SHA (the truncated fallback lists a folder by it).
        var treeSHAs: [String: String] = [:]
        var complete: Bool
        var itemCount: Int { folders.values.reduce(0) { $0 + $1.count } }
    }

    static let maxTrees = 8
    static let maxItems = 400_000

    private struct State {
        var defaultBranches: [String: String] = [:]   // repo → branch
        var commits: [String: String] = [:]           // repo \0 ref → commit
        var refs: [String: [RemoteRef]] = [:]         // repo → refs
        var trees: [String: Tree] = [:]               // repo \0 commit → tree
        var treeOrder: [String] = []                  // keys of `trees`, least recently used first
        var treeItems: [String: Int] = [:]            // key → items in that tree
        var totalItems = 0

        mutating func touch(_ key: String) {
            if let i = treeOrder.firstIndex(of: key) { treeOrder.remove(at: i) }
            treeOrder.append(key)
        }

        mutating func store(_ tree: Tree, _ key: String) {
            trees[key] = tree
            let count = tree.itemCount
            totalItems += count - (treeItems[key] ?? 0)
            treeItems[key] = count
            touch(key)
            while treeOrder.count > 1, treeOrder.count > TreeCache.maxTrees || totalItems > TreeCache.maxItems {
                remove(treeOrder[0])
            }
        }

        mutating func remove(_ key: String) {
            trees[key] = nil
            totalItems -= treeItems.removeValue(forKey: key) ?? 0
            if let i = treeOrder.firstIndex(of: key) { treeOrder.remove(at: i) }
        }
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
    func tree(_ repo: String, _ commit: String) -> Tree? {
        state.withLock { s in
            let key = Self.key(repo, commit)
            guard let tree = s.trees[key] else { return nil }
            s.touch(key)
            return tree
        }
    }
    func setTree(_ tree: Tree, _ repo: String, _ commit: String) {
        state.withLock { $0.store(tree, Self.key(repo, commit)) }
    }
    func addFolder(_ path: String, items: [RemoteItem], childSHAs: [String: String], _ repo: String, _ commit: String) {
        state.withLock { s in
            let key = Self.key(repo, commit)
            var tree = s.trees[key] ?? Tree(complete: false)
            tree.folders[path] = items
            tree.treeSHAs.merge(childSHAs) { _, new in new }
            s.store(tree, key)
        }
    }
    /// From the cached tree of the location's ref (nil once that tree is dropped, or for a ref not listed yet): the
    /// item's kind in its parent's listing, for webURL (blob vs tree).
    func kind(of location: RemoteLocation) -> RemoteItemKind? {
        guard let parent = location.parent, let name = location.name else { return .directory }
        return state.withLock { s in
            guard let ref = location.ref ?? s.defaultBranches[location.repo],
                  let commit = s.commits[Self.key(location.repo, ref)],
                  let items = s.trees[Self.key(location.repo, commit)]?.folders[parent.pathString] else { return nil }
            return items.first { $0.name == name }?.kind
        }
    }
    var treeCount: Int { state.withLock { $0.trees.count } }

    /// Refresh (spec §4.1): forget the ref's commit (or every ref of the repo when nil), its trees, and the refs list.
    func invalidate(repo: String, ref: String?) {
        state.withLock { s in
            let prefix = repo + "\u{0}"
            let refKeys = s.commits.keys.filter { $0.hasPrefix(prefix) && (ref == nil || $0 == Self.key(repo, ref!)) }
            for key in refKeys {
                if let commit = s.commits.removeValue(forKey: key) { s.remove(Self.key(repo, commit)) }
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
        if !complete {   // a truncated listing is cut off partway, so no folder in it (not even the root) is trusted
            tree.folders = [:]
            tree.treeSHAs = [:]
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
