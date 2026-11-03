import Foundation
import Darwin
import MacxFS

enum CopyResult: Sendable, Equatable { case copied, cancelled, failed(Int32) }

struct TreeCopyState: Sendable {
    struct OpenDir: Sendable { var relativePath: String; var source: String; var destination: String }
    var next = 0
    var openDirs: [OpenDir] = []
    var skippedPrefix: String? = nil
    var hadSkips = false
}

enum TreeStep: Sendable, Equatable { case finished, failed(index: Int, code: Int32), cancelled }

/// Callback context for one copyfile call; lives on the lane thread only (never crosses isolation).
final class CopyProgressBox {
    let lane: LaneContext
    let control: JobControl
    let chunk: Int64
    var reported: Int64 = 0
    var nextMark: Int64
    /// errno of a failed read/write reported through COPYFILE_ERR (copyfile would otherwise retry forever).
    var failure: Int32 = 0
    let onBytes: (Int64) -> Void
    let onChunk: () -> Void
    init(lane: LaneContext, control: JobControl, chunk: Int64, onBytes: @escaping (Int64) -> Void, onChunk: @escaping () -> Void) {
        self.lane = lane; self.control = control; self.chunk = max(1, chunk); self.nextMark = max(1, chunk)
        self.onBytes = onBytes; self.onChunk = onChunk
    }
    func progress(_ copied: Int64) {
        if copied > reported { onBytes(copied - reported); reported = copied }
        while copied >= nextMark { nextMark += chunk; onChunk() }
    }
}

enum CopyEngine {
    /// COPYFILE_ALL | DATA_SPARSE | NOFOLLOW_SRC | EXCL (+ CLONE, which also implies EXCL).
    static func fileFlags(clone: Bool) -> copyfile_flags_t {
        var f = copyfile_flags_t(COPYFILE_ACL | COPYFILE_STAT | COPYFILE_XATTR | COPYFILE_DATA)
        f |= copyfile_flags_t(COPYFILE_DATA_SPARSE) | copyfile_flags_t(COPYFILE_NOFOLLOW_SRC) | copyfile_flags_t(COPYFILE_EXCL)
        if clone { f |= copyfile_flags_t(COPYFILE_CLONE) }
        return f
    }
    static let metadataFlags = copyfile_flags_t(COPYFILE_ACL | COPYFILE_STAT | COPYFILE_XATTR)

    /// One file or symlink. Never leaves a half-written destination behind (it is created exclusively,
    /// so on failure other than EEXIST it is ours to unlink).
    static func copyFile(from src: String, to dst: String, expectedSize: Int64, clone: Bool, chunkBytes: Int,
                         lane: LaneContext, control: JobControl,
                         onBytes: @escaping (Int64) -> Void, onChunk: @escaping () -> Void) -> CopyResult {
        assertOffMain()
        guard let state = copyfile_state_alloc() else { return .failed(ENOMEM) }
        defer { copyfile_state_free(state) }
        let box = CopyProgressBox(lane: lane, control: control, chunk: Int64(chunkBytes), onBytes: onBytes, onChunk: onChunk)
        return withExtendedLifetime(box) {
            let callback: copyfile_callback_t = { what, stage, state, _, _, ctx in
                guard let ctx else { return COPYFILE_CONTINUE }
                let box = Unmanaged<CopyProgressBox>.fromOpaque(ctx).takeUnretainedValue()
                if stage == COPYFILE_ERR {
                    // CONTINUE here makes copyfile retry the failed write (e.g. ENOSPC) in an endless loop.
                    box.failure = errno != 0 ? errno : EIO
                    return COPYFILE_QUIT
                }
                if what == COPYFILE_COPY_DATA && stage == COPYFILE_PROGRESS {
                    var copied: off_t = 0
                    _ = copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
                    box.progress(Int64(copied))
                }
                box.lane.heartbeat()
                return box.control.laneCheckpoint(box.lane) ? COPYFILE_CONTINUE : COPYFILE_QUIT
            }
            copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
            copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(box).toOpaque())
            if copyfile(src, dst, state, fileFlags(clone: clone)) == 0 {
                if expectedSize > box.reported { onBytes(expectedSize - box.reported) }   // clone: no callbacks
                return .copied
            }
            let e = box.failure != 0 ? box.failure : errno
            if e != EEXIST { _ = unlink(dst) }
            if control.isCancelled || (box.failure == 0 && e == ECANCELED) { return .cancelled }
            return .failed(e)
        }
    }

    static func makeDirectory(_ dst: String) -> Int32 {
        assertOffMain()
        return mkdir(dst, 0o700) == 0 ? 0 : errno
    }

    /// Post-order: mode, timestamps, BSD flags (uchg), ACL, xattrs.
    static func finalizeDirectory(from src: String, to dst: String) -> Int32 {
        assertOffMain()
        return copyfile(src, dst, nil, metadataFlags) == 0 ? 0 : errno
    }

    static func isUnder(_ rel: String, _ dirRel: String) -> Bool { dirRel.isEmpty || rel.hasPrefix(dirRel + "/") }
    static func join(_ root: String, _ rel: String) -> String { rel.isEmpty ? root : root + "/" + rel }

    /// Resumable: copies item.entries[state.next...]; returns at the first failing entry (state.next stays
    /// on it) so the async side can ask Retry/Skip/Cancel; closes directories post-order; finalizes every
    /// open directory on finish and on cancel.
    static func copyTree(_ item: PlanItem, to destinationRoot: String, state: inout TreeCopyState, clone: Bool,
                         chunkBytes: Int, lane: LaneContext, control: JobControl,
                         progress: @escaping (Int, Int64, String?) -> Void, onChunk: @escaping () -> Void) -> TreeStep {
        assertOffMain()
        let srcRoot = item.source.path
        while state.next < item.entries.count {
            let e = item.entries[state.next]
            if let skipped = state.skippedPrefix {
                if e.relativePath != skipped && isUnder(e.relativePath, skipped) { state.next += 1; continue }
                state.skippedPrefix = nil
            }
            while let top = state.openDirs.last, !isUnder(e.relativePath, top.relativePath) {
                state.openDirs.removeLast()
                _ = finalizeDirectory(from: top.source, to: top.destination)
            }
            guard control.laneCheckpoint(lane) else { finalizeAll(&state); return .cancelled }
            lane.heartbeat()
            let src = join(srcRoot, e.relativePath)
            let dst = join(destinationRoot, e.relativePath)
            let label = e.relativePath.isEmpty ? item.source.lastPathComponent : e.relativePath
            switch e.type {
            case .directory:
                if e.errorCode != 0 { return .failed(index: state.next, code: e.errorCode) }
                let rc = makeDirectory(dst)
                if rc != 0 { return .failed(index: state.next, code: rc) }
                state.openDirs.append(.init(relativePath: e.relativePath, source: src, destination: dst))
                progress(1, 0, label)
            case .file, .symlink:
                let r = copyFile(from: src, to: dst, expectedSize: e.type == .file ? e.size : 0, clone: clone,
                                 chunkBytes: chunkBytes, lane: lane, control: control,
                                 onBytes: { progress(0, $0, nil) }, onChunk: onChunk)
                switch r {
                case .copied: progress(1, 0, label)
                case .cancelled: finalizeAll(&state); return .cancelled
                case .failed(let code): return .failed(index: state.next, code: code)
                }
            case .other:
                return .failed(index: state.next, code: ENOTSUP)   // FIFOs, sockets, devices: never read
            }
            state.next += 1
        }
        finalizeAll(&state)
        return .finished
    }

    static func finalizeAll(_ state: inout TreeCopyState) {
        while let top = state.openDirs.popLast() { _ = finalizeDirectory(from: top.source, to: top.destination) }
    }

    /// Skip the failing entry (and its subtree when it is a directory).
    static func skipEntry(_ item: PlanItem, _ state: inout TreeCopyState) {
        let e = item.entries[state.next]
        if e.type == .directory { state.skippedPrefix = e.relativePath }
        state.next += 1
        state.hadSkips = true
    }
}

enum TreeOutcome: Sendable, Equatable { case completed, partial, skipped, cancelled }

/// Async driver: runs copyTree on a fileOp lane, asks about failing entries, resumes.
enum TreeCopier {
    static func copy(_ ctx: JobContext, _ item: PlanItem, to destination: URL) async -> TreeOutcome {
        var state = TreeCopyState()
        let clone = ctx.tuning.allowClone
        let chunk = ctx.tuning.copyChunkBytes
        let control = ctx.control
        let jobID = ctx.id
        let hook = ctx.tuning.faultHook
        while true {
            let start = state
            let result = try? await ctx.onLane { lane -> (TreeStep, TreeCopyState) in
                var st = start
                let step = CopyEngine.copyTree(item, to: destination.path, state: &st, clone: clone, chunkBytes: chunk,
                                               lane: lane, control: control,
                                               progress: { items, bytes, current in ctx.addProgress(items: items, bytes: bytes, current: current) },
                                               onChunk: { hook?(.midCopyChunk, jobID) })
                return (step, st)
            }
            let (step, newState) = result ?? (.failed(index: state.next, code: EIO), state)
            state = newState
            switch step {
            case .finished:
                return state.hadSkips ? .partial : .completed
            case .cancelled:
                return .cancelled
            case .failed(let index, let code):
                let rel = item.entries[index].relativePath
                let failing = rel.isEmpty ? item.source : item.source.appending(path: rel)
                switch await ctx.resolveFailure(code, url: failing, destination: destination) {
                case .retry:
                    continue
                case .skipped:
                    if index == 0 {
                        let s = state
                        _ = try? await ctx.onLane { _ in var st = s; CopyEngine.finalizeAll(&st) }
                        return .skipped
                    }
                    CopyEngine.skipEntry(item, &state)
                case .cancelled:
                    let s = state
                    _ = try? await ctx.onLane { _ in var st = s; CopyEngine.finalizeAll(&st) }
                    return .cancelled
                }
            }
        }
    }
}
