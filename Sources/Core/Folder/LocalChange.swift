import Foundation

/// Names a file operation changed in one directory (FileOps → ChangeBus → FolderModel, §4.3). The model stats
/// every named item, so the post never has to describe the new state itself.
public struct LocalChange: Sendable, Equatable {
    public struct Rename: Sendable, Equatable {
        public var from: String
        public var to: String
        public init(from: String, to: String) { self.from = from; self.to = to }
    }
    public var directory: URL
    public var added: [String]
    public var removed: [String]
    public var renamed: [Rename]
    public var modified: [String]
    public var select: [String]          // select these names once present
    public var beginRename: String?      // enter inline rename on this name once present (new items)
    /// Added names that were put back where they were removed from (undo of a trash or move): search results
    /// re-insert their rows (Search QA). Always also in `added`.
    public var restored: [String]

    public init(directory: URL, added: [String] = [], removed: [String] = [], renamed: [Rename] = [],
                modified: [String] = [], select: [String] = [], beginRename: String? = nil, restored: [String] = []) {
        self.directory = directory
        self.added = added
        self.removed = removed
        self.renamed = renamed
        self.modified = modified
        self.select = select
        self.beginRename = beginRename
        self.restored = restored
    }

    /// Every name whose current state must be read, without duplicates, in first-mention order.
    var touchedNames: [String] {
        var seen = Set<String>()
        var out: [String] = []
        let all = added + removed + renamed.flatMap { [$0.from, $0.to] } + modified + select + (beginRename.map { [$0] } ?? [])
        for name in all where seen.insert(name).inserted { out.append(name) }
        return out
    }
}
