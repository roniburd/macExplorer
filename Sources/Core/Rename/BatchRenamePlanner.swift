import Foundation
import MacxFS

public enum BatchRenameStatus: Sendable, Equatable {
    case ok, unchanged, invalid(NameProblem), duplicateInBatch, collidesWithExisting(String), invalidPattern(String)
    /// invalid, duplicateInBatch, collidesWithExisting and invalidPattern stop Rename.
    public var blocksApply: Bool {
        switch self {
        case .ok, .unchanged: false
        case .invalid, .duplicateInBatch, .collidesWithExisting, .invalidPattern: true
        }
    }
}

public struct BatchRenameRow: Sendable, Equatable {
    public var url: URL
    public var original: String
    public var proposed: String
    public var status: BatchRenameStatus
    public var extensionChanged: Bool
    public init(url: URL, original: String, proposed: String, status: BatchRenameStatus, extensionChanged: Bool) {
        self.url = url; self.original = original; self.proposed = proposed; self.status = status; self.extensionChanged = extensionChanged
    }
}

public struct BatchRenamePreview: Sendable, Equatable {
    public var rows: [BatchRenameRow]
    public var canApply: Bool
    public init(rows: [BatchRenameRow], canApply: Bool) { self.rows = rows; self.canApply = canApply }
}

/// One item of a `.batchRename` job: `url` gets `newName` in its own folder.
public struct BatchRenamePair: Sendable, Codable, Equatable {
    public var url: URL
    public var newName: String
    public init(url: URL, newName: String) { self.url = url; self.newName = newName }
}

/// Batch-rename preview (P4-11). O(n), no file-system access: safe to run for every keystroke off the main thread.
public enum BatchRenamePlanner {
    /// `urls` in display order (numbering follows it). A URL whose `hasDirectoryPath` is true is a folder (all base name).
    /// `existingNames`: every name in the items' folder (hidden included, from EntryStore), NameNormalizer semantics; pass
    /// [] when the items span folders (search results), where the job reports a name that's taken.
    /// Statuses in priority order: invalidPattern (all rows), invalid (NameRules), unchanged (byte-equal), duplicateInBatch
    /// (every member of a group of equal proposals in the same folder, unchanged rows' names included), collidesWithExisting (an existing name
    /// that is not one of the batch's originals; names being vacated are free), ok.
    public static func preview(_ urls: [URL], rules: BatchRenameRules, caseSensitive: Bool, existingNames: [String]) -> BatchRenamePreview {
        let originals = urls.map(\.lastPathComponent)
        let compiled: BatchRenameRules.Compiled
        do { compiled = try rules.compiled() } catch {
            let pattern: String = switch error { case .invalidPattern(let p): p }
            let rows = zip(urls, originals).map {
                BatchRenameRow(url: $0, original: $1, proposed: $1, status: .invalidPattern(pattern), extensionChanged: false)
            }
            return BatchRenamePreview(rows: rows, canApply: false)
        }
        func key(_ name: String) -> String { NameNormalizer.identityName(name, caseSensitive: caseSensitive) }
        // Items from search results live in several folders: a proposal only clashes with one in the same folder.
        let folders = urls.map { $0.deletingLastPathComponent().standardizedFileURL.path }
        struct Slot: Hashable { var folder: String; var name: String }

        var rows: [BatchRenameRow] = []
        rows.reserveCapacity(urls.count)
        var proposalCount: [Slot: Int] = [:]
        proposalCount.reserveCapacity(urls.count)
        for (i, url) in urls.enumerated() {
            let original = originals[i]
            let isDirectory = url.hasDirectoryPath
            let proposed = compiled.apply(to: original, index: i, isDirectory: isDirectory)
            let fromExt = BatchRenameRules.split(original, isDirectory: isDirectory).ext
            let toExt = BatchRenameRules.split(proposed, isDirectory: isDirectory).ext
            let extensionChanged = !NameNormalizer.sameName(fromExt, toExt, caseSensitive: false)
            let status: BatchRenameStatus
            if case .invalid(let problem) = NameRules.validate(proposed, original: nil, caseSensitive: caseSensitive, exists: { _ in false }) {
                status = .invalid(problem)
            } else {
                status = Array(proposed.utf8) == Array(original.utf8) ? .unchanged : .ok
                proposalCount[Slot(folder: folders[i], name: key(proposed)), default: 0] += 1
            }
            rows.append(BatchRenameRow(url: url, original: original, proposed: proposed, status: status, extensionChanged: extensionChanged))
        }

        let originalKeys = Set(originals.map(key))
        var existing: [String: String] = [:]                  // key → the folder's spelling, minus the batch's originals
        existing.reserveCapacity(existingNames.count)
        for name in existingNames {
            let k = key(name)
            if !originalKeys.contains(k) { existing[k] = name }
        }

        var canApply = false, blocked = false
        for i in rows.indices where rows[i].status == .ok {
            let k = key(rows[i].proposed)
            if (proposalCount[Slot(folder: folders[i], name: k)] ?? 0) > 1 {
                rows[i].status = .duplicateInBatch
            } else if let taken = existing[k] {
                rows[i].status = .collidesWithExisting(taken)
            }
        }
        // Unchanged rows keep their status (they don't move); the rows that would take their names show duplicateInBatch.
        for row in rows {
            if row.status.blocksApply { blocked = true }
            if row.status == .ok { canApply = true }
        }
        return BatchRenamePreview(rows: rows, canApply: canApply && !blocked)
    }

    /// The rows with status `.ok`, in order.
    public static func pairs(_ preview: BatchRenamePreview) -> [BatchRenamePair] {
        preview.rows.filter { $0.status == .ok }.map { BatchRenamePair(url: $0.url, newName: $0.proposed) }
    }
}
