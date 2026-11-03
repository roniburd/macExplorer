import Foundation
import Darwin
import MacxFS

final class RemoveProgressBox {
    let lane: LaneContext
    let control: JobControl
    let onItem: () -> Void
    init(lane: LaneContext, control: JobControl, onItem: @escaping () -> Void) { self.lane = lane; self.control = control; self.onItem = onItem }
}

enum TrashDeleteJobs {
    enum TrashOne: Sendable, Equatable { case done, noTrash, skipped, cancelled }

    /// Trashes one item, asking on errors (Unlock and Continue clears uchg). Records `.trashed` with the
    /// resulting URL and posts the removal. `.noTrash`: the volume has no Trash; the caller decides.
    static func trashOne(_ ctx: JobContext, _ src: URL, identity: FileIdentity) async -> TrashOne {
        let trash = ctx.trash
        while true {
            let result: Result<URL, FileOpError> = (try? await ctx.onLane { _ in
                do { return .success(try trash.trash(src)) }
                catch let e as FileOpError { return .failure(e) }
                catch { return .failure(FileOpError(kind: FileOpErrorKind(error: error, isLockedItem: PosixFS.info(src.path)?.isLocked ?? false), url: src)) }
            }) ?? .failure(FileOpError(kind: .other(code: EIO, message: String(cString: strerror(EIO))), url: src))
            switch result {
            case .success(let trashURL):
                ctx.record(.trashed(original: src, trashURL: trashURL, identity))
                ctx.noteRemoved(src)
                ctx.addProgress(items: 1, current: src.lastPathComponent)
                return .done
            case .failure(let e) where e.kind == .noTrash:
                return .noTrash
            case .failure(let e):
                switch await ctx.askError(e) {
                case .retry, .continueAnyway: continue
                case .unlockAndContinue:
                    _ = try? await ctx.onLane { _ in PosixFS.clearImmutable(src.path, recursive: false) }
                    continue
                case .skip, .skipAll: ctx.skip(src, reason: e.kind); return .skipped
                case .cancel: ctx.cancelJob(); return .cancelled
                }
            }
        }
    }

    static func trash(_ ctx: JobContext, _ urls: [URL]) async {
        guard let plan = await ctx.plan(sources: urls, destination: nil, mode: .shallow) else { return }
        var noTrash: [URL] = []
        for item in plan.items {
            guard await ctx.checkpoint() else { break }
            switch await trashOne(ctx, item.source, identity: item.info.identity) {
            case .noTrash: noTrash.append(item.source)
            case .cancelled: return
            case .done, .skipped: continue
            }
        }
        guard !noTrash.isEmpty, !ctx.control.isCancelled else { return }
        if await ctx.askNoTrash(noTrash) {
            for u in noTrash {
                if await deleteItem(ctx, u) == .cancelled { return }
            }
        } else {
            for u in noTrash { ctx.skip(u, reason: .noTrash) }
        }
    }

    static func delete(_ ctx: JobContext, _ urls: [URL]) async {
        guard let plan = await ctx.plan(sources: urls, destination: nil, mode: .enumerate(noMaterialization: true)) else { return }
        for item in plan.items {
            guard await ctx.checkpoint() else { break }
            if await deleteItem(ctx, item.source) == .cancelled { return }
        }
    }

    /// removefile with a status callback per removed item; Retry after a locked error unlocks the tree.
    static func deleteItem(_ ctx: JobContext, _ url: URL) async -> StepResult {
        let control = ctx.control
        var unlock = false
        while true {
            let u = unlock
            let rc = (try? await ctx.onLane { lane in
                removeWithProgress(url.path, unlock: u, lane: lane, control: control) { ctx.addProgress(items: 1) }
            }) ?? EIO
            if rc == 0 {
                ctx.record(.deleted(url))
                ctx.noteRemoved(url)
                return .done
            }
            if control.isCancelled { return .cancelled }
            let hasLocked = rc == EPERM ? ((try? await ctx.onLane { _ -> Bool in
                var found = false
                PosixFS.walk(url.path) { p, _ in if PosixFS.info(p)?.isLocked == true { found = true }; return !found }
                return found
            }) ?? false) : false
            let kind = FileOpErrorKind(errno: rc, isLockedItem: hasLocked)
            switch await ctx.askError(FileOpError(kind: kind, url: url)) {
            case .retry, .continueAnyway: continue
            case .unlockAndContinue: unlock = true; continue
            case .skip, .skipAll: ctx.skip(url, reason: kind); return .skipped
            case .cancel: ctx.cancelJob(); return .cancelled
            }
        }
    }

    static func removeWithProgress(_ path: String, unlock: Bool, lane: LaneContext, control: JobControl, onItem: @escaping () -> Void) -> Int32 {
        assertOffMain()
        if unlock { PosixFS.clearImmutable(path) }
        guard let state = removefile_state_alloc() else { return ENOMEM }
        defer { removefile_state_free(state) }
        let box = RemoveProgressBox(lane: lane, control: control, onItem: onItem)
        return withExtendedLifetime(box) {
            let callback: removefile_callback_t = { _, _, ctx in
                guard let ctx else { return Int32(REMOVEFILE_PROCEED) }
                let box = Unmanaged<RemoveProgressBox>.fromOpaque(ctx).takeUnretainedValue()
                box.onItem()
                box.lane.heartbeat()
                return box.control.laneCheckpoint(box.lane) ? Int32(REMOVEFILE_PROCEED) : Int32(REMOVEFILE_STOP)
            }
            removefile_state_set(state, UInt32(REMOVEFILE_STATE_STATUS_CALLBACK), unsafeBitCast(callback, to: UnsafeRawPointer.self))
            removefile_state_set(state, UInt32(REMOVEFILE_STATE_STATUS_CONTEXT), Unmanaged.passUnretained(box).toOpaque())
            return removefile(path, state, removefile_flags_t(REMOVEFILE_RECURSIVE)) == 0 ? 0 : errno
        }
    }
}
