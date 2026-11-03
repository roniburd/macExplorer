import Foundation
import Darwin
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
        ctx.rememberConflict(resolution, folder: folder, answering: pending + [source])
        switch resolution {
        case .one(let a), .all(let a): return normalize(a)
        case .perItem(let map): return normalize(map[source] ?? .skip)
        case .cancelJob: ctx.cancelJob(); return nil
        }
    }
}

extension ConflictExecutor {
    struct Trashed: Sendable { var original: URL; var trashURL: URL; var entry: JournalEntry }

    static func execute(_ ctx: JobContext, action: ConflictAction, item: PlanItem, destinationDir: URL, name: String,
                        operation: Operation, renameExcl: Bool) async -> StepResult {
        let target = destinationDir.appending(path: name)
        switch action {
        case .skip:
            ctx.skip(item.source, reason: nil)
            return .skipped
        case .keepBoth:
            let isDir = item.info.isDirectory
            let free = (try? await ctx.onLane { _ in
                NameGenerator.keepBoth(name, isDirectory: isDir) { PosixFS.exists(destinationDir.appending(path: $0).path) }
            }) ?? name
            return await transfer(ctx, item, to: destinationDir.appending(path: free), operation: operation, renameExcl: renameExcl)
        case .replace:
            return await replace(ctx, item: item, target: target, operation: operation, renameExcl: renameExcl)
        case .merge:
            return await merge(ctx, item: item, into: target, operation: operation, renameExcl: renameExcl)
        }
    }

    /// Non-conflicting landing (rules of §6.3).
    static func transfer(_ ctx: JobContext, _ item: PlanItem, to target: URL, operation: Operation, renameExcl: Bool) async -> StepResult {
        switch operation {
        case .copy:
            switch await CopyJob.copyItem(ctx, item, to: target) {
            case .completed: return .done
            case .partial, .skipped: return .skipped
            case .cancelled: return .cancelled
            }
        case .move:
            return await MoveJob.moveItem(ctx, item, to: target, renameExcl: renameExcl)
        }
    }

    /// Trash the existing destination (never delete it), journal its Trash URL, record `.replaced`.
    static func trashExisting(_ ctx: JobContext, _ target: URL) async -> Trashed? {
        let trash = ctx.trash
        while true {
            let result: Result<(URL, FileIdentity?), FileOpError> = (try? await ctx.onLane { _ in
                let id = FileIdentity.of(path: target.path)
                do { return .success((try trash.trash(target), id)) }
                catch let e as FileOpError { return .failure(e) }
                catch { return .failure(FileOpError(kind: FileOpErrorKind(error: error, isLockedItem: false), url: target)) }
            }) ?? .failure(FileOpError(kind: .other(code: EIO, message: String(cString: strerror(EIO))), url: target))
            switch result {
            case .success(let (trashURL, id)):
                let entry = JournalEntry.trashedDestination(job: ctx.id, original: target, trashURL: trashURL)
                // Without this entry a crash would leave the destination in the Trash: ask, and put it back unless retried.
                guard await journalOrAsk(ctx, entry, about: target) else {
                    _ = try? await ctx.onLane { _ in
                        if !PosixFS.exists(target.path) { _ = PosixFS.rename(trashURL.path, target.path) }
                    }
                    return nil
                }
                if let id { ctx.record(.replaced(original: target, trashURL: trashURL, id)) }
                return Trashed(original: target, trashURL: trashURL, entry: entry)
            case .failure(let e):
                switch await ctx.askError(e) {
                case .retry, .continueAnyway: continue
                case .unlockAndContinue:
                    _ = try? await ctx.onLane { _ in PosixFS.clearImmutable(target.path, recursive: false) }
                    continue
                case .cancel: ctx.cancelJob(); return nil
                case .skip, .skipAll: return nil
                }
            }
        }
    }

    /// Journals `entry`; on a write failure asks Retry/Skip/Cancel (EIO). false = not journaled (skipped or cancelled;
    /// the caller lists the item).
    static func journalOrAsk(_ ctx: JobContext, _ entry: JournalEntry, about url: URL) async -> Bool {
        while true {
            do { try await ctx.journalRecord(entry); return true } catch {
                let e = FileOpError(kind: .other(code: EIO, message: String(cString: strerror(EIO))), url: url)
                switch await ctx.askError(e) {
                case .retry, .continueAnyway, .unlockAndContinue: continue
                case .skip, .skipAll: return false
                case .cancel: ctx.cancelJob(); return false
                }
            }
        }
    }

    /// Put the trashed destination back (its original path is free because the new item did not land).
    static func restore(_ ctx: JobContext, _ trashed: Trashed) async {
        _ = try? await ctx.onLane { _ in
            if !PosixFS.exists(trashed.original.path) { _ = PosixFS.rename(trashed.trashURL.path, trashed.original.path) }
        }
        ctx.removeLastAction { if case .replaced(_, let t, _) = $0 { t == trashed.trashURL } else { false } }
        await ctx.journalClear(trashed.entry)
    }

    static func replace(_ ctx: JobContext, item: PlanItem, target: URL, operation: Operation, renameExcl: Bool) async -> StepResult {
        let src = item.source
        if operation == .move && item.sameVolume {
            // Nothing is copied, so the source can't be lost: trash existing, then the rename primitive.
            guard let trashed = await trashExisting(ctx, target) else {
                if !ctx.control.isCancelled { ctx.skip(src, reason: nil) }
                return ctx.control.isCancelled ? .cancelled : .skipped
            }
            ctx.fault(.afterTrashDestination)
            let r = await MoveJob.moveItem(ctx, item, to: target, renameExcl: renameExcl)
            if r == .done { await ctx.journalClear(trashed.entry) } else { await restore(ctx, trashed) }
            return r
        }
        // Copy or cross-volume move: partial → verify → trash existing → rename → (move) delete source.
        let partial = target.deletingLastPathComponent().appending(path: PartialName.make(for: target.lastPathComponent, job: ctx.id))
        let entry = JournalEntry.partial(job: ctx.id, url: partial)
        guard await journalOrAsk(ctx, entry, about: src) else {
            if !ctx.control.isCancelled { ctx.skip(src, reason: nil) }
            return ctx.control.isCancelled ? .cancelled : .skipped
        }
        let copied = await TreeCopier.copy(ctx, item, to: partial)
        guard copied == .completed else {
            await MoveJob.removePartial(ctx, partial, entry)
            return copied == .cancelled ? .cancelled : .skipped
        }
        ctx.fault(.afterPartialCopy)
        let verified = (try? await ctx.onLane { _ -> Bool in
            let a = PosixFS.treeStats(src.path), b = PosixFS.treeStats(partial.path)
            return a.items == b.items && a.bytes == b.bytes
        }) ?? false
        guard verified else {
            await MoveJob.removePartial(ctx, partial, entry)
            switch await ctx.askError(FileOpError(kind: .changedDuringMove, url: src, destination: target)) {
            case .retry, .continueAnyway, .unlockAndContinue:
                return await replace(ctx, item: item, target: target, operation: operation, renameExcl: renameExcl)
            case .skip, .skipAll: ctx.skip(src, reason: .changedDuringMove); return .skipped
            case .cancel: ctx.cancelJob(); return .cancelled
            }
        }
        guard let trashed = await trashExisting(ctx, target) else {
            await MoveJob.removePartial(ctx, partial, entry)
            if !ctx.control.isCancelled { ctx.skip(src, reason: nil) }
            return ctx.control.isCancelled ? .cancelled : .skipped
        }
        ctx.fault(.afterTrashDestination)
        ctx.fault(.beforePartialRename)
        let renamed = await MoveJob.renamePartial(ctx, partial, to: target)
        guard renamed == .renamed else {
            await restore(ctx, trashed)
            await MoveJob.removePartial(ctx, partial, entry)
            let code: Int32 = switch renamed { case .exists: EEXIST; case .crossDevice: EXDEV; case .failed(let e): e; case .renamed: 0 }
            switch await ctx.resolveFailure(code, url: src, destination: target) {
            case .retry: return await replace(ctx, item: item, target: target, operation: operation, renameExcl: renameExcl)
            case .skipped: return .skipped
            case .cancelled: return .cancelled
            }
        }
        await ctx.journalClear(entry)
        await ctx.journalClear(trashed.entry)
        switch operation {
        case .copy:
            if let id = (try? await ctx.onLane({ _ in FileIdentity.of(path: target.path) })) ?? nil { ctx.record(.created(target, id)) }
            ctx.landed(target)
        case .move:
            ctx.fault(.beforeSourceDelete)
            await MoveJob.finishMove(ctx, source: src, target: target)
        }
        return .done
    }

    /// Folder onto folder: children that don't exist land with the normal rules; conflicting children
    /// follow the dialog (recursively). For a move the source folder is removed only once empty.
    static func merge(_ ctx: JobContext, item: PlanItem, into target: URL, operation: Operation, renameExcl: Bool) async -> StepResult {
        let src = item.source
        let force = ctx.tuning.forceCrossVolume
        let children = (try? await ctx.onLane { _ in
            ((try? FileManager.default.contentsOfDirectory(atPath: src.path)) ?? []).sorted()
        }) ?? []
        var result: StepResult = .done
        for child in children {
            guard await ctx.checkpoint() else { return .cancelled }
            let childSrc = src.appending(path: child)
            let childDst = target.appending(path: child)
            let planned = try? await ctx.onLane { lane -> (PlanItem?, Bool) in
                let p = Planner.plan(sources: [childSrc], destination: target, mode: operation == .copy ? .copy : .move,
                                     forceCrossVolume: force, lane: lane)
                return (p.items.first, PosixFS.exists(childDst.path))
            }
            guard case let (childItem?, conflicting)? = planned else { continue }
            let r: StepResult
            if conflicting {
                guard let action = await decide(ctx, source: childSrc, target: childDst, pending: [childSrc], destinationDir: target) else {
                    return .cancelled
                }
                r = await execute(ctx, action: action, item: childItem, destinationDir: target, name: child,
                                  operation: operation, renameExcl: renameExcl)
            } else {
                r = await transfer(ctx, childItem, to: childDst, operation: operation, renameExcl: renameExcl)
            }
            if r == .cancelled { return .cancelled }
            if r == .skipped { result = .skipped }
        }
        if operation == .move {
            let removed = (try? await ctx.onLane { _ in rmdir(src.path) == 0 }) ?? false
            if removed { ctx.noteRemoved(src) }
        }
        return result
    }
}
