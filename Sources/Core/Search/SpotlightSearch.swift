import Foundation
import MacxFS

public enum SpotlightSearch {
    public static let resultLimit = 100_000

    public static func events(_ request: SpotlightRequest, query: any MetadataQuerying, includeHidden: Bool,
                              generation: Generation, types: TypeRegistry = .shared) -> AsyncStream<SearchEvent> {
        events(request, query: query, includeHidden: includeHidden, generation: generation, types: types, limit: resultLimit)
    }

    static func events(_ request: SpotlightRequest, query: any MetadataQuerying, includeHidden: Bool,
                       generation: Generation, types: TypeRegistry, limit: Int) -> AsyncStream<SearchEvent> {
        let (stream, out) = AsyncStream.makeStream(of: SearchEvent.self, bufferingPolicy: .unbounded)
        if SpotlightPredicate.matchesNothing(request.criteria) {         // never start a query that cannot match
            out.yield(.completed(SearchSummary(resultCount: 0, elapsed: .zero)))
            out.finish()
            return stream
        }
        let task = Task {
            let clock = ContinuousClock()
            let start = clock.now
            var filter = PostFilter(request: request, includeHidden: includeHidden, types: types)
            var count = 0, completed = false
            loop: for await event in query.run(request) {
                if Task.isCancelled { break }
                switch event {
                case .added(var items):
                    items = items.filter { filter.accepts($0) }
                    var truncated = false
                    if items.count > limit - count { items = Array(items.prefix(limit - count)); truncated = true }
                    for b in batches(items, generation: generation, types: types) { out.yield(.batch(b)) }
                    count += items.count
                    if truncated {
                        out.yield(.completed(SearchSummary(resultCount: count, truncated: true, elapsed: clock.now - start)))
                        break loop
                    }
                case .updated(let items):
                    let (keep, drop) = items.reduce(into: ([MetadataItem](), [String]())) { acc, item in
                        if filter.accepts(item) { acc.0.append(item) } else { acc.1.append(item.path) }
                    }
                    for b in batches(keep, generation: generation, types: types) { out.yield(.batch(b)) }
                    if !drop.isEmpty { out.yield(.removed(drop)) }
                case .removed(let paths):
                    out.yield(.removed(paths))
                case .gatheringFinished:
                    if !completed {
                        completed = true
                        out.yield(.completed(SearchSummary(resultCount: count, elapsed: clock.now - start)))
                    }
                case .failed:
                    out.yield(.failed(.spotlightFailed))
                    break loop
                }
            }
            out.finish()
        }
        out.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Path checks compare folded keys (CrawlPermissions.fold: NFC, lowercased, "/private/var|tmp|etc" folded):
    /// Spotlight reports the real path (/private/var/..., the on-disk case) while the planner keeps the caller's
    /// spelling (contract note 15). Symlinked roots are not resolved here (the planner is lexical only).
    struct PostFilter {
        let request: SpotlightRequest
        let includeHidden: Bool
        let types: TypeRegistry
        var matcher: CriteriaMatcher
        let within: String?
        let parent: String?
        let scopeRoots: [String]
        init(request: SpotlightRequest, includeHidden: Bool, types: TypeRegistry) {
            self.request = request; self.includeHidden = includeHidden; self.types = types
            matcher = CriteriaMatcher(request.criteria, types: types)
            within = request.within.map { CrawlPermissions.fold(CrawlRun.standardized($0)) }
            parent = request.directChildrenOf.map { CrawlPermissions.fold(CrawlRun.standardized($0)) }
            if case .folders(let urls) = request.scope {
                scopeRoots = urls.map { CrawlPermissions.fold(CrawlRun.standardized($0)) }
            } else { scopeRoots = [] }
        }
        mutating func accepts(_ item: MetadataItem) -> Bool {
            let key = CrawlPermissions.fold(item.path)
            if let within, !Self.isBelow(key, within) { return false }
            if let parent, LexicalPath.parent(of: key) != parent { return false }
            if !includeHidden && (item.isInvisible || hasHiddenComponent(key)) { return false }
            let (entry, name) = SpotlightSearch.entry(for: item, types: types)
            return SortKeys.searchFold(name).withUnsafeBytes { matcher.matches(entry, foldedName: $0) }
        }

        /// Strictly below `base` (both folded).
        static func isBelow(_ key: String, _ base: String) -> Bool {
            base == "/" ? key.count > 1 : key.hasPrefix(base + "/")
        }

        /// A "." component below the search root (the user may already be looking inside a hidden folder, like
        /// the crawler, which only skips hidden items it meets below its root). `key` is the folded item path.
        func hasHiddenComponent(_ key: String) -> Bool {
            let base = parent ?? within ?? scopeRoots.first { Self.isBelow(key, $0) }
            var rest = Substring(key)
            if let base, base == "/" || rest.hasPrefix(base + "/") { rest = rest.dropFirst(base == "/" ? 1 : base.count + 1) }
            return rest.split(separator: "/").contains { $0.hasPrefix(".") }
        }
    }

    static func batches(_ items: [MetadataItem], generation: Generation, types: TypeRegistry) -> [SearchBatch] {
        var order: [String] = []
        var byParent: [String: Batch] = [:]
        for item in items {
            let parent = (item.path as NSString).deletingLastPathComponent
            if byParent[parent] == nil { order.append(parent); byParent[parent] = Batch(generation: generation) }
            let (entry, name) = entry(for: item, types: types)
            Array(name.utf8).withUnsafeBufferPointer { byParent[parent]!.append(entry, nameBytes: $0) }
        }
        return order.map { SearchBatch(parent: URL(filePath: $0, directoryHint: .isDirectory), batch: byParent[$0]!) }
    }

    public static func entry(for item: MetadataItem, types: TypeRegistry) -> (entry: Entry, name: String) {
        let name = item.name
        let tree = item.contentTypeTree
        let isDir = tree.contains("public.directory") || tree.contains("public.folder")
        let ext = Substring((name as NSString).pathExtension)
        var kind: Kind = tree.contains("public.symlink") ? .symlink : .file
        var typeIndex = types.index(forExtension: ext, isDirectory: isDir)
        if isDir {
            if types.isPackage(typeIndex) { kind = .package } else { kind = .directory; typeIndex = TypeRegistry.folderIndex }
        }
        var flags: EntryFlags = [.readable]
        if name.hasPrefix(".") { flags.insert(.dotName) } else if item.isInvisible { flags.insert(.bsdHidden) }
        func ns(_ d: Date?) -> Int64 { d.map { Int64(($0.timeIntervalSince1970 * 1e9).rounded()) } ?? 0 }
        let id = fnv1a(item.path)
        let entry = Entry(rowID: id, fileID: id, size: isDir && kind == .directory ? 0 : (item.size ?? 0),
                          allocSize: item.size ?? 0, mtime: ns(item.modified), ctime: ns(item.created),
                          nameOffset: 0, nameLen: UInt16(min(name.utf8.count, Int(UInt16.max))), kind: kind,
                          flags: flags, typeIndex: typeIndex)
        return (entry, name)
    }

    /// Stable synthetic row id (results identity is the path; IconCache only needs a stable value).
    static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h ^= UInt64(b); h &*= 0x0000_0100_0000_01B3 }
        return h
    }
}
