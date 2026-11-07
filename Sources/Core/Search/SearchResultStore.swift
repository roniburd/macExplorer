import Foundation
import MacxFS

/// Results of one search: entries from many folders. Identity is the full path (`RowID.name`), never the inode
/// (inode numbers repeat across volumes), so the wrapped store's identity map is never consulted.
///
/// Path forms (contract for P3-05/P3-06): `SearchBatch.parent`, `remove(paths:)`, `rename(path:)` and
/// `index(ofPath:)` accept any spelling of a path: "/private/var/…" or "/var/…", with or without "."/".." or a
/// trailing slash. Normalization is purely lexical (never `standardizedFileURL`, which stats the path and drops
/// "/private" only when it exists, and must not run on the main actor). Shown paths, URLs and identities keep
/// the spelling of the first batch for each folder (lexically cleaned); lookups compare `MountTable.standardize`
/// keys, so the crawler's, Spotlight's and the change bus's spellings all find the same row.
public struct SearchResultStore: Sendable {
    public private(set) var store = EntryStore(identityMode: .objectID)
    /// `SortKeys.nameKey` of each entry's Finder display name (extensions shown per the item's own flag), by storage
    /// index; kept aligned with `store` by append, remove and rename.
    public private(set) var nameKeys = SortKeyColumn()
    public private(set) var parents: [String] = []
    private var parentLookup: [String: UInt32] = [:]    // keyed by MountTable.standardize(parent)
    private var parentOf: [UInt32] = []                 // by storage index
    private var pathIndex: [String: UInt32] = [:]       // keyed by MountTable.standardize(full path)

    public init() {}

    public var count: Int { store.count }

    public func parentIndex(_ index: UInt32) -> UInt32 { parentOf[Int(index)] }
    public func parentPath(_ index: UInt32) -> String { parents[Int(parentOf[Int(index)])] }
    public func path(_ index: UInt32) -> String { Self.join(parentPath(index), store.name(index)) }
    public func url(_ index: UInt32) -> URL {
        let kind = store.entry(index).kind
        return URL(filePath: path(index), directoryHint: kind == .directory || kind == .package ? .isDirectory : .notDirectory)
    }
    /// The name shown in result rows (Finder display-name rule; results carry no localized stems).
    public func displayName(_ index: UInt32, showAllExtensions: Bool) -> String {
        store.displayName(index, showAllExtensions: showAllExtensions)
    }
    public func identity(_ index: UInt32) -> RowID { .name(path(index)) }
    public func index(ofPath path: String) -> UInt32? { pathIndex[Self.key(path)] }

    /// Lookup key: lexical, "/private/var|tmp|etc" folded to "/var|tmp|etc".
    static func key(_ path: String) -> String { MountTable.standardize(path) }

    static func join(_ parent: String, _ name: String) -> String { parent == "/" ? "/" + name : parent + "/" + name }

    /// Lexically cleaned path (no ".", "..", duplicate or trailing slashes; "/" stays "/") in the caller's spelling:
    /// a leading "/private" is kept. No file-system access.
    static func standardizedParent(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        guard path.hasPrefix("/") else { return path }
        var parts: [Substring] = []
        for c in path.split(separator: "/", omittingEmptySubsequences: true) {
            if c == "." { continue }
            if c == ".." { _ = parts.popLast(); continue }
            parts.append(c)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// Appends the batch at the end of storage (not displayed until the caller merges the indices into the order).
    /// A path already present is replaced: its old entry is removed first. Returns the new storage indices.
    @discardableResult
    public mutating func append(_ batch: SearchBatch) -> [UInt32] {
        guard batch.batch.count > 0 else { return [] }
        let spelled = Self.standardizedParent(batch.parent)
        let parentKey = Self.key(spelled)
        let paths = (0..<batch.batch.count).map { Self.join(parentKey, batch.batch.name(at: $0)) }   // lookup keys
        removeIndices(Set(paths.compactMap { pathIndex[$0] }))
        let p: UInt32
        if let known = parentLookup[parentKey] {
            p = known
        } else {
            p = UInt32(parents.count)
            parents.append(spelled)
            parentLookup[parentKey] = p
        }
        let start = store.count
        store.append(batch.batch)
        nameKeys.append(contentsOf: SortKeys.nameKeys(store, range: start..<store.count))
        parentOf.append(contentsOf: repeatElement(p, count: paths.count))
        for (offset, path) in paths.enumerated() { pathIndex[path] = UInt32(start + offset) }
        return (start..<store.count).map(UInt32.init)
    }

    /// Removes the given full paths (unknown ones are ignored). Returns how many entries were removed.
    @discardableResult
    public mutating func remove(paths: [String]) -> Int {
        let indices = Set(paths.compactMap { pathIndex[Self.key($0)] })
        removeIndices(indices)
        return indices.count
    }

    /// Remove + append of a re-typed entry (new name, new type from the new extension, dot-name flag). The renamed
    /// entry is appended at the end and is not in the order; the caller merges it.
    public mutating func rename(path: String, to newName: String, types: TypeRegistry) -> Bool {
        guard let index = pathIndex[Self.key(path)] else { return false }
        var entry = store.entry(index)
        let parentURL = URL(filePath: parentPath(index), directoryHint: .isDirectory)
        if entry.kind != .directory {
            entry.typeIndex = types.index(forExtension: Substring((newName as NSString).pathExtension),
                                          isDirectory: entry.kind == .package)
        }
        entry.flags.remove(.dotName)
        if newName.hasPrefix(".") { entry.flags.insert(.dotName) }
        var batch = Batch(generation: .initial)
        Array(newName.utf8).withUnsafeBufferPointer { batch.append(entry, nameBytes: $0) }
        removeIndices([index])
        append(SearchBatch(parent: parentURL, batch: batch))
        return true
    }

    public mutating func setOrder(_ order: [UInt32]) { store.setOrder(order) }

    /// Stable compaction of every column (survivors keep their relative order); `store.remove` remaps the order.
    private mutating func removeIndices(_ indices: Set<UInt32>) {
        guard !indices.isEmpty else { return }
        store.remove(indices)
        nameKeys.remove(indices)
        var keptParents: [UInt32] = []
        keptParents.reserveCapacity(parentOf.count - indices.count)
        for (i, p) in parentOf.enumerated() where !indices.contains(UInt32(i)) { keptParents.append(p) }
        parentOf = keptParents
        // Each survivor moves down by the number of removed indices below it.
        let removed = indices.sorted()
        var remapped: [String: UInt32] = [:]
        remapped.reserveCapacity(pathIndex.count - indices.count)
        for (path, i) in pathIndex where !indices.contains(i) {
            var lo = 0, hi = removed.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if removed[mid] < i { lo = mid + 1 } else { hi = mid }
            }
            remapped[path] = i - UInt32(lo)
        }
        pathIndex = remapped
    }
}
