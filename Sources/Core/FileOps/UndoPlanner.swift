import Foundation
import Darwin
import MacxFS

/// One inverse step of §6.6, derived from one recorded ItemAction.
enum UndoStep: Sendable, Equatable {
    case trash(URL, FileIdentity)
    case remove(URL, FileIdentity)
    case removeDirectoryIfEmpty(URL, FileIdentity)
    case moveBack(current: URL, original: URL, FileIdentity)
    case renameBack(current: URL, original: URL, FileIdentity)
    case restoreMode(URL, expected: UInt16, restore: UInt16)
    case restoreAttributes(URL, expected: AttributeSnapshot, restore: AttributeSnapshot)
    case restoreIcon(URL, expected: IconImageData?, restore: IconImageData?)

    var isRestoreMode: Bool { if case .restoreMode = self { true } else { false } }
}

/// Body of `.undo(record)` and `.redo(record)` jobs (§6.6). Never overwrites; checks identity first.
enum UndoPlanner {
    enum Presence: Sendable, Equatable { case same, gone, changed }
    struct MadeDirectory: Sendable { var url: URL; var identity: FileIdentity }

    /// Pure. Inverse steps, last action first. nil when the record is not undoable (empty, or any `.deleted`).
    static func steps(for record: JobRecord) -> [UndoStep]? {
        guard record.isUndoable else { return nil }
        let removesLinks = record.verb == .makingAlias || record.verb == .makingSymlink
        return record.actions.reversed().compactMap { action -> UndoStep? in
            switch action {
            case .created(let u, let id): removesLinks ? .remove(u, id) : .trash(u, id)
            case .createdDirectory(let u, let id): .removeDirectoryIfEmpty(u, id)
            case .moved(let from, let to, let id): .moveBack(current: to, original: from, id)
            case .renamed(let from, let to, let id): .renameBack(current: to, original: from, id)
            case .trashed(let original, let t, let id), .replaced(let original, let t, let id):
                .moveBack(current: t, original: original, id)
            case .modeChanged(let u, let old, let new): .restoreMode(u, expected: new, restore: old)
            case .attributesChanged(let u, let old, let new): .restoreAttributes(u, expected: new, restore: old)
            case .customIconChanged(let u, let previous, let new): .restoreIcon(u, expected: new, restore: previous)
            case .deleted: nil
            }
        }
    }

    static func run(_ ctx: JobContext, _ record: JobRecord) async {
        guard let steps = steps(for: record) else { return }
        ctx.setTotals(items: steps.count, bytes: nil)
        ctx.setState(.running)
        var index = 0
        while index < steps.count {
            guard await ctx.checkpoint() else { return }
            if steps[index].isRestoreMode {
                var end = index
                while end < steps.count, steps[end].isRestoreMode { end += 1 }
                let finished = await restoreModes(ctx, Array(steps[index..<end]))
                index = end
                ctx.setItemsDone(index)
                guard finished else { return }
            } else {
                let result = await perform(ctx, steps[index])
                index += 1
                ctx.setItemsDone(index)
                if result == .cancelled { return }
            }
        }
    }

    static func perform(_ ctx: JobContext, _ step: UndoStep) async -> StepResult {
        switch step {
        case .trash(let u, let id): return await trashCreated(ctx, u, id)
        case .remove(let u, let id): return await remove(ctx, u, id)
        case .removeDirectoryIfEmpty(let u, let id): return await removeDirectoryIfEmpty(ctx, u, id)
        case .moveBack(let c, let o, let id): return await moveBack(ctx, current: c, original: o, id)
        case .renameBack(let c, let o, let id): return await renameBack(ctx, current: c, original: o, id)
        case .restoreMode: return await restoreModes(ctx, [step]) ? .done : .cancelled
        case .restoreAttributes(let u, let e, let r): return await restoreAttributes(ctx, u, expected: e, restore: r)
        case .restoreIcon(let u, let e, let r): return await IconJobs.restoreIcon(ctx, u, expected: e, restore: r)
        }
    }

    // MARK: identity

    /// Lane only.
    static func presence(_ url: URL, _ id: FileIdentity) -> Presence {
        assertOffMain()
        guard let info = PosixFS.info(url.path) else { return .gone }
        return info.identity == id ? .same : .changed
    }

    /// Skips (and lists) items that have gone or changed. true = act.
    static func check(_ ctx: JobContext, _ url: URL, _ id: FileIdentity) async -> Bool {
        switch (try? await ctx.onLane { _ in presence(url, id) }) ?? .gone {
        case .same: return true
        case .gone: ctx.skip(url, reason: .sourceGone); return false
        case .changed: ctx.skip(url, reason: .changedDuringMove); return false
        }
    }

    // MARK: created items

    static func trashCreated(_ ctx: JobContext, _ url: URL, _ id: FileIdentity) async -> StepResult {
        guard await check(ctx, url, id) else { return .skipped }
        switch await TrashDeleteJobs.trashOne(ctx, url, identity: id) {
        case .done: return .done
        case .skipped: return .skipped
        case .cancelled: return .cancelled
        case .noTrash:
            guard await ctx.askNoTrash([url]) else { ctx.skip(url, reason: .noTrash); return .skipped }
            return await TrashDeleteJobs.deleteItem(ctx, url)
        }
    }

    /// Alias / symlink: removed (§6.6). The undo record then holds `.deleted`, so it has no redo.
    static func remove(_ ctx: JobContext, _ url: URL, _ id: FileIdentity) async -> StepResult {
        guard await check(ctx, url, id) else { return .skipped }
        let result = await ctx.attempt(url) { _ in PosixFS.removeTree(url.path) }
        if result == .done {
            ctx.record(.deleted(url))
            ctx.noteRemoved(url)
        }
        return result
    }

    /// A folder a merge (or an earlier undo) created: removed only once empty; otherwise left alone, silently.
    static func removeDirectoryIfEmpty(_ ctx: JobContext, _ url: URL, _ id: FileIdentity) async -> StepResult {
        let removed = (try? await ctx.onLane { _ in presence(url, id) == .same && rmdir(url.path) == 0 }) ?? false
        if removed { ctx.noteRemoved(url) }
        return .done
    }

    // MARK: moves and renames

    enum Landing { case at(URL, displaced: ConflictExecutor.Trashed?), skipped, cancelled }

    /// An occupied original path goes through the conflict question (§6.6). Undo never overwrites:
    /// Skip leaves both, Keep Both (and Merge) picks the next free name, Replace trashes the occupant.
    static func landing(_ ctx: JobContext, current: URL, original: URL, _ id: FileIdentity) async -> Landing {
        let parent = original.deletingLastPathComponent()
        // Same identity at the original spelling = a case/normalization-only rename of this very item.
        let occupied = (try? await ctx.onLane { _ in PosixFS.info(original.path).map { $0.identity != id } ?? false }) ?? false
        guard occupied else { return .at(original, displaced: nil) }
        guard let action = await ConflictExecutor.decide(ctx, source: current, target: original, pending: [], destinationDir: parent) else {
            return .cancelled
        }
        switch action {
        case .skip:
            ctx.skip(current, reason: nil)
            return .skipped
        case .keepBoth, .merge:
            let free = (try? await ctx.onLane { _ -> String in
                let isDir = PosixFS.info(current.path)?.isDirectory ?? false
                return NameGenerator.keepBoth(original.lastPathComponent, isDirectory: isDir) { PosixFS.exists(parent.appending(path: $0).path) }
            }) ?? original.lastPathComponent
            return .at(parent.appending(path: free), displaced: nil)
        case .replace:
            guard let trashed = await ConflictExecutor.trashExisting(ctx, original) else {
                if ctx.control.isCancelled { return .cancelled }
                ctx.skip(current, reason: nil)
                return .skipped
            }
            return .at(original, displaced: trashed)
        }
    }

    /// Moves `current` back to `original` (same volume: rename primitive; otherwise partial → verify →
    /// rename → delete, P1-21). Trash URLs and moved items both come back this way.
    static func moveBack(_ ctx: JobContext, current: URL, original: URL, _ id: FileIdentity) async -> StepResult {
        guard await check(ctx, current, id) else { return .skipped }
        let target: URL
        let displaced: ConflictExecutor.Trashed?
        switch await landing(ctx, current: current, original: original, id) {
        case .at(let t, let d): target = t; displaced = d
        case .skipped: return .skipped
        case .cancelled: return .cancelled
        }
        let parentReady = await ensureParent(ctx, of: target, for: current)
        guard parentReady == .done else {
            if let displaced { await ConflictExecutor.restore(ctx, displaced) }
            return parentReady
        }
        let parent = target.deletingLastPathComponent()
        let force = ctx.tuning.forceCrossVolume
        let planned = try? await ctx.onLane { lane in
            Planner.plan(sources: [current], destination: parent, mode: .move, forceCrossVolume: force, lane: lane)
        }
        guard let plan = planned, let item = plan.items.first else {
            if let displaced { await ConflictExecutor.restore(ctx, displaced) }
            ctx.skip(current, reason: .sourceGone)
            return .skipped
        }
        let result = await MoveJob.moveItem(ctx, item, to: target, renameExcl: plan.capabilities.renameExcl)
        if let displaced {
            if result == .done { await ctx.journalClear(displaced.entry) } else { await ConflictExecutor.restore(ctx, displaced) }
        }
        return result
    }

    static func renameBack(_ ctx: JobContext, current: URL, original: URL, _ id: FileIdentity) async -> StepResult {
        guard current.deletingLastPathComponent().standardizedFileURL.path
                == original.deletingLastPathComponent().standardizedFileURL.path else {
            return await moveBack(ctx, current: current, original: original, id)
        }
        guard await check(ctx, current, id) else { return .skipped }
        switch await landing(ctx, current: current, original: original, id) {
        case .at(let target, let displaced):
            let result = await CreateOps.performRename(ctx, current, to: target.lastPathComponent)
            if let displaced {
                if result == .done { await ctx.journalClear(displaced.entry) } else { await ConflictExecutor.restore(ctx, displaced) }
            }
            return result
        case .skipped: return .skipped
        case .cancelled: return .cancelled
        }
    }

    /// Lane only: `mkdir -p` of `directory`, returning the folders it created, outermost first. 0 or errno.
    static func makeMissingDirectories(_ directory: URL) -> (code: Int32, made: [MadeDirectory]) {
        assertOffMain()
        var missing: [String] = []
        var path = directory.standardizedFileURL.path
        while path != "/", !path.isEmpty, !PosixFS.exists(path) {
            missing.append(path)
            path = (path as NSString).deletingLastPathComponent
        }
        var made: [MadeDirectory] = []
        for dir in missing.reversed() {
            if mkdir(dir, 0o777) != 0 {
                let e = errno
                if e == EEXIST { continue }          // someone else made it: not ours to remove later
                return (e, made)
            }
            if let id = FileIdentity.of(path: dir) {
                made.append(MadeDirectory(url: URL(filePath: dir, directoryHint: .isDirectory), identity: id))
            }
        }
        return (0, made)
    }

    /// Re-creates missing parents of `target` (e.g. the source folder a merge-move removed once empty) and records
    /// them as `.createdDirectory`, so the inverse removes them again once empty.
    static func ensureParent(_ ctx: JobContext, of target: URL, for item: URL) async -> StepResult {
        let parent = target.deletingLastPathComponent()
        while true {
            let r = (try? await ctx.onLane { _ in makeMissingDirectories(parent) }) ?? (code: EIO, made: [])
            for d in r.made {
                ctx.record(.createdDirectory(d.url, d.identity))
                ctx.noteAdded(d.url)
            }
            if r.code == 0 { return .done }
            switch await ctx.resolveFailure(r.code, url: item, destination: parent) {
            case .retry: continue
            case .skipped: return .skipped
            case .cancelled: return .cancelled
            }
        }
    }

    // MARK: modes and attributes

    /// Consecutive mode restores run in one lane call (chmodRecursive of a large tree); failures are asked per item.
    /// false = the job was cancelled.
    static func restoreModes(_ ctx: JobContext, _ steps: [UndoStep]) async -> Bool {
        struct ModeItem: Sendable { var url: URL; var expected: UInt16; var restore: UInt16 }
        enum ModeResult: Sendable { case done, gone, changed, failed(Int32) }
        let items: [ModeItem] = steps.compactMap {
            if case .restoreMode(let u, let e, let r) = $0 { ModeItem(url: u, expected: e, restore: r) } else { nil }
        }
        let control = ctx.control
        let results: [ModeResult] = (try? await ctx.onLane { lane -> [ModeResult] in
            var out: [ModeResult] = []
            out.reserveCapacity(items.count)
            for (i, m) in items.enumerated() {
                if i % 256 == 0 { lane.heartbeat(); if !control.laneCheckpoint(lane) { break } }
                guard let info = PosixFS.info(m.url.path) else { out.append(.gone); continue }
                guard info.mode == m.expected else { out.append(.changed); continue }
                let rc = PosixFS.setMode(m.url.path, m.restore)
                out.append(rc == 0 ? .done : .failed(rc))
            }
            return out
        }) ?? items.map { _ in .failed(EIO) }
        let paths = Set(items.map { $0.url.standardizedFileURL.path })
        for (i, m) in items.enumerated() {
            guard i < results.count else { return false }               // the lane stopped at a cancel
            var outcome = results[i]
            retry: while case .failed(let code) = outcome {
                switch await ctx.resolveFailure(code, url: m.url) {
                case .retry:
                    outcome = (try? await ctx.onLane { _ in
                        let rc = PosixFS.setMode(m.url.path, m.restore)
                        return rc == 0 ? ModeResult.done : .failed(rc)
                    }) ?? .failed(EIO)
                case .skipped: break retry
                case .cancelled: return false
                }
            }
            switch outcome {
            case .done:
                ctx.record(.modeChanged(m.url, old: m.expected, new: m.restore))
                // One post per changed subtree: items whose parent is also in the batch are covered by it.
                if !paths.contains(m.url.deletingLastPathComponent().standardizedFileURL.path) { ctx.noteModified(m.url) }
            case .gone: ctx.skip(m.url, reason: .sourceGone)
            case .changed: ctx.skip(m.url, reason: .changedDuringMove)
            case .failed: break                                          // skipped by resolveFailure
            }
        }
        return !control.isCancelled
    }

    /// Lane only. Current values of exactly the fields `template` sets.
    static func currentValues(_ url: URL, like template: AttributeSnapshot) -> AttributeSnapshot? {
        var out = AttributeSnapshot()
        if template.locked != nil {
            guard let s = AttributeJobs.snapshot(url, for: .locked(false)) else { return nil }
            out.locked = s.locked
        }
        if template.hidden != nil {
            guard let s = AttributeJobs.snapshot(url, for: .hidden(false)) else { return nil }
            out.hidden = s.hidden
        }
        if template.extensionHidden != nil {
            guard let s = AttributeJobs.snapshot(url, for: .extensionHidden(false)) else { return nil }
            out.extensionHidden = s.extensionHidden
        }
        if template.mode != nil {
            guard let s = AttributeJobs.snapshot(url, for: .permissions(0)) else { return nil }
            out.mode = s.mode
        }
        if template.quarantine != nil {
            guard let s = AttributeJobs.snapshot(url, for: .removeQuarantine) else { return nil }
            out.quarantine = s.quarantine
        }
        if template.acl != nil {
            guard let s = AttributeJobs.snapshot(url, for: .acl([])) else { return nil }
            out.acl = s.acl
        }
        return out
    }

    /// Properties edits: restore the recorded previous value (quarantine: rewrite the saved xattr), only while
    /// the item still has the value the job set.
    static func restoreAttributes(_ ctx: JobContext, _ url: URL, expected: AttributeSnapshot, restore: AttributeSnapshot) async -> StepResult {
        while true {
            let r = (try? await ctx.onLane { _ -> (Presence, Int32) in
                guard PosixFS.exists(url.path) else { return (.gone, 0) }
                guard currentValues(url, like: expected) == expected else { return (.changed, 0) }
                return (.same, AttributeJobs.apply(restore, to: url))
            }) ?? (.same, EIO)
            switch r {
            case (.gone, _):
                ctx.skip(url, reason: .sourceGone)
                return .skipped
            case (.changed, _):
                ctx.skip(url, reason: .changedDuringMove)
                return .skipped
            case (.same, 0):
                ctx.record(.attributesChanged(url, old: expected, new: restore))
                ctx.noteModified(url)
                return .done
            case (.same, let code):
                switch await ctx.resolveFailure(code, url: url) {
                case .retry: continue
                case .skipped: return .skipped
                case .cancelled: return .cancelled
                }
            }
        }
    }
}
