import Foundation
import MacxFS

enum ConflictExecutor {
    enum Operation: Sendable, Equatable { case copy, move }

    static func summary(_ url: URL) -> ItemSummary? {
        guard let i = PosixFS.info(url.path) else { return nil }
        return ItemSummary(url: url, isDirectory: i.isDirectory, size: i.size, modified: i.mtime)
    }

    /// §6.4: asks once per conflict unless an "all" (per class: file/file or folder/folder) or per-item
    /// (Compare) answer applies. Replace on folder/folder means Merge (as in Explorer); Merge on a
    /// non-folder pair means Keep Both. nil = the user cancelled the job.
    static func decide(_ ctx: JobContext, source: URL, target: URL, pending: [URL], destinationDir: URL) async -> ConflictAction? {
        let summaries = try? await ctx.onLane { _ -> (ItemSummary?, ItemSummary?, [ConflictPair]) in
            let pairs = pending.compactMap { p -> ConflictPair? in
                guard let s = summary(p), let d = summary(destinationDir.appending(path: p.lastPathComponent)) else { return nil }
                return ConflictPair(source: s, destination: d)
            }
            return (summary(source), summary(target), pairs)
        }
        guard case let (s?, d?, pairs)? = summaries else { return .skip }
        let folder = s.isDirectory && d.isDirectory
        func normalize(_ a: ConflictAction) -> ConflictAction {
            switch (a, folder) {
            case (.replace, true): .merge
            case (.merge, false): .keepBoth
            default: a
            }
        }
        if let remembered = ctx.rememberedConflictAction(folder: folder, source: source) { return normalize(remembered) }
        let info = ConflictInfo(pair: ConflictPair(source: s, destination: d), isFolderMerge: folder,
                                knownRemaining: max(1, pairs.count), pendingPairs: pairs.isEmpty ? [ConflictPair(source: s, destination: d)] : pairs)
        let resolution = await ctx.askConflict(info)
        ctx.rememberConflict(resolution, folder: folder)
        switch resolution {
        case .one(let a), .all(let a): return normalize(a)
        case .perItem(let map): return normalize(map[source] ?? .skip)
        case .cancelJob: ctx.cancelJob(); return nil
        }
    }
}
