import Foundation
import MacxPluginKit
import Synchronization

/// In-memory provider for tests. Addresses: `fake:<repo>[@ref][/path…]` (repo is one segment, e.g. `fake:demo@main/src`;
/// tests that need a "/" in a repo name build `RemoteLocation` values directly). Trees are keyed by "repo@ref", then
/// by path ("" = root). `init(tree:defaultRef:)` installs a fallback tree served for ANY repo. Lists yield two chunks
/// when there are 2+ items (exercises multi-batch reads).
public final class FakeRemoteProvider: RemoteProvider {
    public let id: String
    public let displayName: String
    public let iconSymbol = "shippingbox"

    private struct State {
        var trees: [String: [String: [RemoteItem]]] = [:]          // "repo@ref" → path → items
        var anyRepoTree: [String: [String: [RemoteItem]]] = [:]    // ref → path → items (any repo)
        var refsByRepo: [String: [RemoteRef]] = [:]
        var refs: [RemoteRef]?                                      // fallback for any repo
        var nextFailure: RemoteError?
        var failure: RemoteError?                                   // every call throws while set
        var calls: [String] = []
        var invalidations: [(repo: String, ref: String?)] = []
        var fetchCount = 0
        var defaultRef = "main"
    }
    private let state = Mutex(State())

    public init(id: String = "test.fake", displayName: String = "Fake") {
        self.id = id
        self.displayName = displayName
    }

    /// Part B style: one tree (ref → path → items) served for every repo.
    public convenience init(tree: [String: [String: [RemoteItem]]], defaultRef: String = "main",
                            id: String = "test.fake", displayName: String = "Fake") {
        self.init(id: id, displayName: displayName)
        state.withLock { $0.anyRepoTree = tree; $0.defaultRef = defaultRef }
    }

    // MARK: test controls

    public func setTree(repo: String, ref: String = "main", _ tree: [String: [RemoteItem]]) {
        state.withLock { $0.trees["\(repo)@\(ref)"] = tree }
    }
    public func setRefs(repo: String, _ refs: [RemoteRef]) { state.withLock { $0.refsByRepo[repo] = refs } }
    public func failNext(_ error: RemoteError) { state.withLock { $0.nextFailure = error } }
    public func failAlways(_ error: RemoteError?) { failure = error }
    public var refs: [RemoteRef] {
        get { state.withLock { $0.refs ?? [] } }
        set { state.withLock { $0.refs = newValue } }
    }
    public var failure: RemoteError? {
        get { state.withLock { $0.failure } }
        set { state.withLock { $0.failure = newValue } }
    }
    public var defaultRef: String {
        get { state.withLock { $0.defaultRef } }
        set { state.withLock { $0.defaultRef = newValue } }
    }
    public var calls: [String] { state.withLock { $0.calls } }
    public var invalidations: [(repo: String, ref: String?)] { state.withLock { $0.invalidations } }
    public var fetchCount: Int { state.withLock { $0.fetchCount } }

    private func record(_ call: String) -> RemoteError? {
        state.withLock { s in
            s.calls.append(call)
            if let e = s.failure { return e }
            defer { s.nextFailure = nil }
            return s.nextFailure
        }
    }

    private func items(repo: String, ref: String, path: String) -> [RemoteItem]? {
        state.withLock { $0.trees["\(repo)@\(ref)"]?[path] ?? $0.anyRepoTree[ref]?[path] }
    }

    // MARK: RemoteProvider

    public func parseAddress(_ text: String) -> RemoteLocation? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("fake:") else { return nil }
        var parts = t.dropFirst(5).split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty else { return nil }
        var repo = parts.removeFirst(), ref: String?
        if let at = repo.firstIndex(of: "@") { ref = String(repo[repo.index(after: at)...]); repo = String(repo[..<at]) }
        guard !repo.isEmpty, ref?.isEmpty != true else { return nil }
        return RemoteLocation(provider: id, repo: repo, ref: ref, path: parts)
    }

    public func completions(for text: String) async -> [String] {
        let repos = state.withLock { Set($0.trees.keys.map { String($0.split(separator: "@")[0]) }) }
        return repos.map { "fake:\($0)" }.filter { $0.hasPrefix(text) }.sorted()
    }

    public func displayRoot(_ location: RemoteLocation) -> String { location.repo }

    /// nil: tests of Copy Path / "Open on…" use a provider whose webURL is set (GitHub) or assert the nil fallback.
    public func webURL(_ location: RemoteLocation) -> URL? { nil }

    public func listRefs(repo: String) async throws(RemoteError) -> [RemoteRef] {
        if let e = record("refs \(repo)") { throw e }
        return state.withLock { $0.refsByRepo[repo] ?? $0.refs } ?? [RemoteRef(name: defaultRef, kind: .branch)]
    }

    public func resolveRef(_ location: RemoteLocation) async throws(RemoteError) -> RemoteLocation {
        if let e = record("resolve \(location.repo)") { throw e }
        return location.ref == nil ? location.withRef(defaultRef) : location
    }

    public func list(_ location: RemoteLocation) -> AsyncThrowingStream<[RemoteItem], any Error> {
        let ref = location.ref ?? defaultRef
        let failure = record("list \(location.repo)@\(ref)/\(location.pathString)")
        let items = items(repo: location.repo, ref: ref, path: location.pathString)
        return AsyncThrowingStream { c in
            if let failure { c.finish(throwing: failure); return }
            guard let items else { c.finish(throwing: RemoteError.notFound); return }
            let half = items.count / 2
            if half > 0 { c.yield(Array(items[..<half])) }
            c.yield(Array(items[half...]))
            c.finish()
        }
    }

    public func fetch(_ location: RemoteLocation, item: RemoteItem, to destination: URL) async throws(RemoteError) {
        if let e = record("fetch \(location.repo)/\(location.pathString)") { throw e }
        state.withLock { $0.fetchCount += 1 }
        do {
            if item.kind == .directory {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            } else {
                try Data("content of \(location.pathString)".utf8).write(to: destination, options: .withoutOverwriting)
            }
        } catch { throw .network(String(describing: error)) }
    }

    public func invalidate(repo: String, ref: String?) {
        _ = record("invalidate \(repo)@\(ref ?? "-")")
        state.withLock { $0.invalidations.append((repo: repo, ref: ref)) }
    }
}
