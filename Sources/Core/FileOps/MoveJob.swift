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
            if src.deletingLastPathComponent().standardizedFileURL.path == destination.standardizedFileURL.path { continue }
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
                    // P1-22 replaces this case with ConflictExecutor.execute(...).
                    ctx.skip(src, reason: nil)
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
                ctx.addProgress(items: item.itemCount, bytes: item.byteCount, current: src.lastPathComponent)
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
    static func crossVolume(_ ctx: JobContext, _ item: PlanItem, to target: URL) async -> StepResult {
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
            let copied = await TreeCopier.copy(ctx, item, to: partial)
            guard copied == .completed else {
                await removePartial(ctx, partial, entry)
                return copied == .cancelled ? .cancelled : .skipped
            }
            ctx.fault(.afterPartialCopy)
            let verified = (try? await ctx.onLane { _ -> Bool in
                let a = PosixFS.treeStats(src.path), b = PosixFS.treeStats(partial.path)
                return a.items == b.items && a.bytes == b.bytes
            }) ?? false
            guard verified else {
                await removePartial(ctx, partial, entry)
                switch await ctx.askError(FileOpError(kind: .changedDuringMove, url: src, destination: target)) {
                case .retry, .continueAnyway, .unlockAndContinue: continue
                case .skip, .skipAll: ctx.skip(src, reason: .changedDuringMove); return .skipped
                case .cancel: ctx.cancelJob(); return .cancelled
                }
            }
            ctx.fault(.beforePartialRename)
            let renamed = (try? await ctx.onLane { _ in RenamePrimitive.rename(partial.path, target.path, renameExcl: true) }) ?? .failed(EIO)
            guard renamed == .renamed else {
                await removePartial(ctx, partial, entry)
                let code: Int32 = switch renamed { case .exists: EEXIST; case .crossDevice: EXDEV; case .failed(let e): e; case .renamed: 0 }
                switch await ctx.resolveFailure(code, url: src, destination: target) {
                case .retry: continue
                case .skipped: return .skipped
                case .cancelled: return .cancelled
                }
            }
            await ctx.journalClear(entry)
            ctx.fault(.beforeSourceDelete)
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
            if let id { ctx.record(removed ? .moved(from: src, to: target, id) : .created(target, id)) }
            if removed { ctx.noteRemoved(src) }
            ctx.landed(target)
            return .done
        }
    }

    static func removePartial(_ ctx: JobContext, _ partial: URL, _ entry: JournalEntry) async {
        _ = try? await ctx.onLane { _ in PosixFS.removeTree(partial.path, unlock: true) }
        await ctx.journalClear(entry)
    }
}
