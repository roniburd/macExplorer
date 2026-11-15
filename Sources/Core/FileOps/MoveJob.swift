import Foundation
import Darwin
import MacxFS

enum MoveJob {
    static func run(_ ctx: JobContext, sources: [URL], destination: URL) async {
        guard let plan = await ctx.plan(sources: sources, destination: destination, mode: .move) else { return }
        var pending = plan.topLevelConflicts
        var first = true
        for item in plan.items {
            guard await ctx.checkpoint() else { break }
            let src = item.source
            // By identity: a symlinked or differently-cased spelling of the source's own folder is that folder.
            let parent = src.deletingLastPathComponent()
            if (try? await ctx.onLane({ _ in PosixFS.isSameDirectory(parent, destination) })) ?? false { continue }
            let isDir = item.info.isDirectory
            var name = src.lastPathComponent
            if (try? await ctx.onLane({ _ in PosixFS.exists(destination.appending(path: src.lastPathComponent).path) })) == true {
                let target = destination.appending(path: name)
                guard let action = await ConflictExecutor.decide(ctx, source: src, target: target, pending: pending, destinationDir: destination) else { break }
                pending.removeAll { $0 == src }
                switch action {
                case .skip:
                    ctx.skip(src, reason: nil)
                    continue
                case .keepBoth:
                    name = (try? await ctx.onLane { _ in
                        NameGenerator.keepBoth(src.lastPathComponent, isDirectory: isDir) { PosixFS.exists(destination.appending(path: $0).path) }
                    }) ?? name
                case .replace, .merge:
                    let r = await ConflictExecutor.execute(ctx, action: action, item: item, destinationDir: destination, name: name,
                                                           operation: .move, renameExcl: plan.capabilities.renameExcl)
                    if r == .cancelled { return }
                    continue
                }
            }
            _ = await moveItem(ctx, item, to: destination.appending(path: name), renameExcl: plan.capabilities.renameExcl)
            if first { first = false; ctx.fault(.afterFirstItem) }
        }
    }

    /// Same volume: rename primitive (EXDEV → re-plan deep and move across volumes). Otherwise cross-volume.
    static func moveItem(_ ctx: JobContext, _ item: PlanItem, to target: URL, renameExcl: Bool) async -> StepResult {
        guard item.sameVolume else { return await crossVolume(ctx, item, to: target) }
        let src = item.source
        while true {
            let outcome = (try? await ctx.onLane { _ in RenamePrimitive.rename(src.path, target.path, renameExcl: renameExcl) }) ?? .failed(EIO)
            let code: Int32
            switch outcome {
            case .renamed:
                if let id = (try? await ctx.onLane({ _ in FileIdentity.of(path: target.path) })) ?? nil {
                    ctx.record(.moved(from: src, to: target, id))
                }
                ctx.noteRemoved(src)
                ctx.landed(target)
                // A rename writes no data: its bytes count as cloned (QA round 2).
                ctx.addProgress(items: item.itemCount, bytes: item.byteCount, cloned: item.byteCount, current: src.lastPathComponent)
                return .done
            case .crossDevice:
                let info = item.info
                let entries = (try? await ctx.onLane { lane in Planner.enumerate(src, info: info, noMaterialization: false, lane: lane) })
                var deep = item
                deep.sameVolume = false
                if let entries { deep.entries = entries.entries }
                return await crossVolume(ctx, deep, to: target)
            case .exists: code = EEXIST
            case .failed(let e): code = e
            }
            switch await ctx.resolveFailure(code, url: src, destination: target) {
            case .retry: continue
            case .skipped: return .skipped
            case .cancelled: return .cancelled
            }
        }
    }

    /// §6.3: partial copy → verify → rename into place → delete source. The source is never deleted
    /// unless the verified copy is at its final name.
    static func crossVolume(_ ctx: JobContext, _ planned: PlanItem, to target: URL) async -> StepResult {
        var item = planned
        let src = item.source
        let partial = target.deletingLastPathComponent().appending(path: PartialName.make(for: target.lastPathComponent, job: ctx.id))
        let entry = JournalEntry.partial(job: ctx.id, url: partial)
        while true {
            do { try await ctx.journalRecord(entry) } catch {
                switch await ctx.resolveFailure(EIO, url: src, destination: target) {
                case .retry: continue
                case .skipped: return .skipped
                case .cancelled: return .cancelled
                }
            }
            let mark = ctx.progressMark()
            let copied = await TreeCopier.copy(ctx, item, to: partial)
            guard copied == .completed else {
                await removePartial(ctx, partial, entry)
                // A skipped child keeps the whole item at the source: list the item too, not only the child.
                if copied == .partial { ctx.skip(src, reason: ctx.lastSkipReason()) }
                return copied == .cancelled ? .cancelled : .skipped
            }
            ctx.fault(.afterPartialCopy)
            let entries = item.entries
            let verified = (try? await ctx.onLane { _ in MoveVerification.verify(source: src, copy: partial, entries: entries) }) ?? false
            guard verified else {
                // The source changed (or the copy is incomplete): the source is never deleted; the unverified copy goes.
                await removePartial(ctx, partial, entry)
                switch await ctx.askError(FileOpError(kind: .changedDuringMove, url: src, destination: target)) {
                case .retry, .continueAnyway, .unlockAndContinue:
                    ctx.restoreProgress(mark)
                    item = await MoveVerification.refreshed(ctx, item)
                    continue
                case .skip, .skipAll: ctx.skip(src, reason: .changedDuringMove); return .skipped
                case .cancel: ctx.cancelJob(); return .cancelled
                }
            }
            ctx.fault(.beforePartialRename)
            let renamed = await renamePartial(ctx, partial, to: target)
            guard renamed == .renamed else {
                await removePartial(ctx, partial, entry)
                let code: Int32 = switch renamed { case .exists: EEXIST; case .crossDevice: EXDEV; case .failed(let e): e; case .renamed: 0 }
                switch await ctx.resolveFailure(code, url: src, destination: target) {
                case .retry: ctx.restoreProgress(mark); continue
                case .skipped: return .skipped
                case .cancelled: return .cancelled
                }
            }
            await ctx.journalClear(entry)
            ctx.fault(.beforeSourceDelete)
            await finishMove(ctx, item, target: target)
            return .done
        }
    }

    /// After the verified copy is at `target`: delete the source (asking on failure; Retry also clears
    /// uchg), record moved, post the changes. When the user skips (or cancels) the deletion, the copy is recorded as
    /// created only while the source is still whole: removefile may have deleted part of it, and Undo trashes a
    /// created item, which would then be the only complete copy. Otherwise the item has no undo.
    static func finishMove(_ ctx: JobContext, _ item: PlanItem, target: URL) async {
        let src = item.source
        let id = (try? await ctx.onLane({ _ in FileIdentity.of(path: target.path) })) ?? nil
        var removed = false
        var unlock = false
        deleting: while true {
            let u = unlock
            let rc = (try? await ctx.onLane { _ in PosixFS.removeTree(src.path, unlock: u) }) ?? EIO
            if rc == 0 { removed = true; break deleting }
            switch await ctx.resolveFailure(rc, url: src) {
            case .retry: unlock = true; continue deleting
            case .skipped, .cancelled: break deleting
            }
        }
        if removed {
            if let id { ctx.record(.moved(from: src, to: target, id)) }
            ctx.noteRemoved(src)
        } else {
            let entries = item.entries
            let whole = (try? await ctx.onLane { _ in MoveVerification.sourceUnchanged(src, entries) }) ?? false
            if whole, let id { ctx.record(.created(target, id)) }
        }
        ctx.landed(target)
    }

    /// Renames the verified partial into place (never overwriting). A locked source's uchg is lifted from the
    /// partial for the rename and put back on the final item.
    static func renamePartial(_ ctx: JobContext, _ partial: URL, to target: URL) async -> RenameOutcome {
        (try? await ctx.onLane { _ -> RenameOutcome in
            let locked = CopyEngine.unlockPartialRoot(partial.path)
            let r = RenamePrimitive.rename(partial.path, target.path, renameExcl: true)
            if locked { CopyEngine.relock(r == .renamed ? target.path : partial.path) }
            return r
        }) ?? .failed(EIO)
    }

    static func removePartial(_ ctx: JobContext, _ partial: URL, _ entry: JournalEntry) async {
        _ = try? await ctx.onLane { _ in PosixFS.removeTree(partial.path, unlock: true) }
        await ctx.journalClear(entry)
    }
}

/// §6.3 cross-volume verification, before the source is deleted. The plan's entries are the "before" snapshot (relative
/// path, type, size, mtime, pre-order); each check is one walk.
enum MoveVerification {
    /// Lane only. The source still matches the snapshot and the copy holds all of it.
    static func verify(source: URL, copy: URL, entries: [PlanEntry]) -> Bool {
        sourceUnchanged(source, entries) && copyComplete(copy, entries)
    }

    /// Lane only. Same paths in the same order with the same types; files and links also the same size and mtime (a
    /// same-size rewrite during the copy is caught). Folder sizes and times are not compared: their contents are.
    static func sourceUnchanged(_ root: URL, _ entries: [PlanEntry]) -> Bool {
        assertOffMain()
        let rootPath = root.path, rootBytes = rootPath.utf8.count
        var i = 0
        var ok = true
        PosixFS.walk(rootPath) { path, ent in
            guard ok else { return false }
            let now = Planner.entry(path: path, ent, rootBytes: rootBytes)
            guard i < entries.count, now.errorCode == 0 else { ok = false; return false }
            let was = entries[i]
            i += 1
            guard was.relativePath == now.relativePath, was.type == now.type else { ok = false; return false }
            if was.type == .file || was.type == .symlink, was.size != now.size || was.mtime != now.mtime { ok = false }
            return ok
        }
        return ok && i == entries.count
    }

    /// Lane only. Every snapshot entry is in the copy with the same type (files: the same size). Extra items in the copy
    /// (AppleDouble "._" files some volumes add) are ignored: they can't stand for anything of the source.
    static func copyComplete(_ root: URL, _ entries: [PlanEntry]) -> Bool {
        assertOffMain()
        var expected = Dictionary(entries.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        guard expected.count == entries.count else { return false }
        let rootPath = root.path, rootBytes = rootPath.utf8.count
        var ok = true
        PosixFS.walk(rootPath) { path, ent in
            guard ok else { return false }
            let now = Planner.entry(path: path, ent, rootBytes: rootBytes)
            guard let was = expected.removeValue(forKey: now.relativePath) else { return true }
            if now.errorCode != 0 || was.type != now.type || (was.type == .file && was.size != now.size) { ok = false }
            return ok
        }
        return ok && expected.isEmpty
    }

    /// The item re-enumerated (Retry after a change): the next copy and check use what is there now.
    static func refreshed(_ ctx: JobContext, _ item: PlanItem) async -> PlanItem {
        let fresh = try? await ctx.onLane { lane -> PlanItem? in
            guard let info = PosixFS.info(item.source.path) else { return nil }
            var p = item
            p.info = info
            p.entries = Planner.enumerate(item.source, info: info, noMaterialization: false, lane: lane).entries
            return p
        }
        return (fresh ?? nil) ?? item
    }
}
