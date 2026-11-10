import Foundation
import Darwin
import MacxFS

/// `.compress` jobs (P4-09): Finder-compatible zip (`ditto`) and Apple Archive (`aa`) next to the first source.
///
/// The archive is written to a journaled partial (`PartialName`, so `LaunchRecovery` removes it after a crash) and
/// renamed to the next free name with RENAME_EXCL. Several sources (or any `.aar`) are first cloned into a journaled
/// staging folder beside them, so the archive holds them at its top level as Finder's does. The sources are only read.
enum CompressJob {
    enum StageFailure: Error, Sendable { case failed(URL, Int32) }

    static func compress(_ ctx: JobContext, _ sources: [URL], _ format: ArchiveFormat) async {
        guard let first = sources.first, format.canCreate else { return }
        guard let plan = await ctx.plan(sources: sources, destination: nil, mode: .enumerate(noMaterialization: true)) else { return }
        let items = plan.items
        guard !items.isEmpty, await ctx.checkpoint() else { return }
        let kept = items.map(\.source)
        let parent = first.deletingLastPathComponent()
        let name = ArchiveNaming.outputName(for: kept, format: format)
        // ditto lists files only ("N bytes for <path>"); that is what progress counts.
        let filesTotal = items.reduce(0) { $0 + $1.entries.filter { $0.type != .directory }.count }
        ctx.setTotals(items: filesTotal, bytes: plan.totalBytes)

        let partial = parent.appending(path: PartialName.make(for: name, job: ctx.id))
        let needsStaging = !(kept.count == 1 && format == .zip)
        let staging = parent.appending(path: PartialName.make(for: name + " staging", job: ctx.id), directoryHint: .isDirectory)
        for entry in [JournalEntry.partial(job: ctx.id, url: partial)] + (needsStaging ? [.partial(job: ctx.id, url: staging)] : []) {
            do { try await ctx.journalRecord(entry) } catch {
                if await ctx.resolveFailure(EIO, url: first) == .skipped { for s in kept.dropFirst() { ctx.skip(s, reason: nil) } }
                return
            }
        }

        let tool = { (path: String) in ctx.tuning.toolOverride?(path) ?? path }
        let (executable, arguments): (String, [String]) = switch (format, needsStaging) {
        case (.zip, false): (tool("/usr/bin/ditto"), ["-c", "-k", "--sequesterRsrc", "--keepParent", "-V", kept[0].path, partial.path])
        case (.zip, true): (tool("/usr/bin/ditto"), ["-c", "-k", "--sequesterRsrc", "-V", staging.path, partial.path])
        default: (tool("/usr/bin/aa"), ["archive", "-d", staging.path, "-o", partial.path, "-a", "lzfse"])
        }
        let control = ctx.control
        let clone = ctx.tuning.allowClone
        let chunk = ctx.tuning.copyChunkBytes
        let start = ctx.progressMark()

        while true {
            ctx.restoreProgress(start)
            let attempt: Result<ProcessResult, any Error>
            do {
                attempt = .success(try await ctx.onLane { lane in
                    if needsStaging { try stage(items, into: staging, clone: clone, chunk: chunk, lane: lane, control: control) }
                    return try ProcessRunner.run(executable, arguments, context: lane,
                                                 isPaused: { control.isPaused }, isCancelled: { control.isCancelled },
                                                 onStarted: { ctx.fault(.archiveToolStarted) },
                                                 onStderrLine: { line in progress(ctx, line) })
                })
            } catch { attempt = .failure(error) }
            _ = try? await ctx.onLane { _ in if needsStaging { _ = PosixFS.removeTree(staging.path, unlock: true) } }
            let succeeded = if case .success(let r) = attempt, r.status == 0, !control.isCancelled { true } else { false }
            if !succeeded { _ = try? await ctx.onLane { _ in unlink(partial.path) } }
            if control.isCancelled { ctx.cancelJob(); return }
            switch attempt {
            case .success(let r) where r.status == 0:
                ctx.restoreProgress((items: filesTotal, bytes: plan.totalBytes, cloned: start.cloned))
                await place(ctx, partial: partial, in: parent, name: name, sources: kept)
                return
            case .success(let r):
                let kind = errorKind(stderrTail: r.stderrTail, status: r.status)
                switch await ctx.askError(FileOpError(kind: kind, url: first)) {
                case .retry, .continueAnyway, .unlockAndContinue: continue
                case .cancel: ctx.cancelJob(); return
                case .skip, .skipAll: for s in kept { ctx.skip(s, reason: kind) }; return
                }
            case .failure(let error):
                if (error as? LaneError) == .cancelled { ctx.cancelJob(); return }
                let (url, code): (URL, Int32) = switch error {
                case StageFailure.failed(let u, let c): (u, c)
                default: (first, (error as? any ErrnoCarrying)?.errnoCode ?? EIO)
                }
                switch await ctx.resolveFailure(code, url: url) {
                case .retry: continue
                case .skipped: for s in kept where s != url { ctx.skip(s, reason: nil) }; return
                case .cancelled: return
                }
            }
        }
    }

    /// A failed tool run: "No space left on device" anywhere in its stderr is `.noSpace`, otherwise `.other` with the
    /// last stderr line (or the exit status).
    static func errorKind(stderrTail: String, status: Int32) -> FileOpErrorKind {
        if stderrTail.contains("No space left on device") { return .noSpace(needed: nil, available: nil) }
        let last = stderrTail.split(whereSeparator: \.isNewline).last.map { $0.trimmingCharacters(in: .whitespaces) }
        return .other(code: EIO, message: last.flatMap { $0.isEmpty ? nil : $0 } ?? "exit \(status)")
    }

    /// ditto -V prints "N bytes for ./path" once per file it stored.
    private static func progress(_ ctx: JobContext, _ line: String) {
        guard let m = line.wholeMatch(of: /(\d+) bytes for (.+?)\s*/), let bytes = Int64(m.1) else { return }
        ctx.addProgress(items: 1, bytes: bytes, current: (String(m.2) as NSString).lastPathComponent)
    }

    /// Lane: clones (or copies) every item into `staging` under its own name. Throws `StageFailure` naming the
    /// source entry that failed, or `LaneError.cancelled`.
    private static func stage(_ items: [PlanItem], into staging: URL, clone: Bool, chunk: Int,
                              lane: LaneContext, control: JobControl) throws {
        _ = PosixFS.removeTree(staging.path, unlock: true)              // a previous attempt's leftovers
        guard mkdir(staging.path, 0o700) == 0 else { throw StageFailure.failed(staging, errno) }
        for item in items {
            var state = TreeCopyState()
            let target = staging.appending(path: item.source.lastPathComponent).path
            switch CopyEngine.copyTree(item, to: target, state: &state, clone: clone, chunkBytes: chunk, lane: lane,
                                       control: control, progress: { _, _, _ in }, onChunk: {}) {
            case .finished: continue
            case .cancelled: throw LaneError.cancelled
            case .failed(let index, let code):
                let rel = item.entries[index].relativePath
                throw StageFailure.failed(rel.isEmpty ? item.source : item.source.appending(path: rel), code)
            }
        }
    }

    /// Renames the finished partial to `name`, or the next free "name 2.ext", … (RENAME_EXCL; a name taken meanwhile
    /// moves on to the next one). Records `.created` so Undo moves the archive to the Trash.
    private static func place(_ ctx: JobContext, partial: URL, in parent: URL, name: String, sources: [URL]) async {
        enum Placed: Sendable { case placed(URL, FileIdentity?), failed(Int32) }
        while true {
            let r = (try? await ctx.onLane { _ -> Placed in
                func taken(_ n: String) -> Bool { PosixFS.exists(parent.appending(path: n).path) }
                for _ in 0..<10_000 {
                    let candidate = taken(name) ? NameGenerator.keepBoth(name, isDirectory: false, taken: taken) : name
                    let final = parent.appending(path: candidate)
                    switch RenamePrimitive.rename(partial.path, final.path, renameExcl: true) {
                    case .renamed: return .placed(final, FileIdentity.of(path: final.path))
                    case .exists: continue
                    case .crossDevice: return .failed(EXDEV)
                    case .failed(let e): return .failed(e)
                    }
                }
                return .failed(EEXIST)
            }) ?? .failed(EIO)
            switch r {
            case .placed(let final, let identity):
                if let identity { ctx.record(.created(final, identity)) }
                ctx.landed(final)
                return
            case .failed(let code):
                switch await ctx.resolveFailure(code, url: sources[0]) {
                case .retry: continue
                case .skipped, .cancelled:
                    _ = try? await ctx.onLane { _ in unlink(partial.path) }
                    for s in sources.dropFirst() { ctx.skip(s, reason: nil) }
                    return
                }
            }
        }
    }
}
