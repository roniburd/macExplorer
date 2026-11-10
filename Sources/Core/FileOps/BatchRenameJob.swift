import Foundation
import Darwin
import MacxFS

/// Cycle-safe batch rename (P4-11): every item goes original → temporary (phase 1), then temporary → target
/// (phase 2), so swaps, chains, cycles and case-only renames need no special path and nothing is ever overwritten.
/// The plan is journaled before the first rename; launch recovery puts every item back at its original name.
enum BatchRenameJob {
    /// One item to rename. `expected`: undo/redo only rename the item that is still the one they recorded.
    struct Item: Sendable, Equatable {
        var url: URL
        var newName: String
        var expected: FileIdentity?
    }

    static func run(_ ctx: JobContext, _ pairs: [BatchRenamePair]) async {
        ctx.setTotals(items: pairs.count, bytes: 0)
        ctx.setState(.running)
        for a in await execute(ctx, pairs.map { Item(url: $0.url, newName: $0.newName, expected: nil) }) { ctx.record(a) }
    }

    static func temporaryName(job: JobID, index: Int) -> String { ".macx-br-\(job.short)-\(index)" }

    private enum Built: Sendable { case step(BatchRenameStep, renameExcl: Bool), skip(URL, FileOpErrorKind?) }

    /// Two-phase executor shared by the forward job, undo and redo. Returns the `.renamed` actions (callers record
    /// them) and posts each rename. Items it can't rename are listed in the job's skipped items.
    static func execute(_ ctx: JobContext, _ items: [Item]) async -> [ItemAction] {
        let job = ctx.id
        let built: [Built] = (try? await ctx.onLane { lane -> [Built] in
            var out: [Built] = []
            var excl: [String: Bool] = [:]
            var seen = Set<String>()
            for (i, item) in items.enumerated() {
                if i % 256 == 0 { lane.heartbeat() }
                let name = item.newName
                if name.isEmpty || name == "." || name == ".." || name.utf8.contains(UInt8(ascii: "/")) {
                    out.append(.skip(item.url, .other(code: EINVAL, message: String(cString: strerror(EINVAL))))); continue
                }
                if NameNormalizer.nfc(name).utf8.count > NameRules.maxNameBytes { out.append(.skip(item.url, .nameTooLong)); continue }
                guard seen.insert(item.url.standardizedFileURL.path).inserted else { continue }    // listed twice
                guard let id = FileIdentity.of(path: item.url.path) else { out.append(.skip(item.url, .sourceGone)); continue }
                if let expected = item.expected, expected != id { out.append(.skip(item.url, .changedDuringMove)); continue }
                let dir = item.url.deletingLastPathComponent()
                let dirPath = dir.standardizedFileURL.path
                let renameExcl = excl[dirPath] ?? VolumeIdentity.capabilities(of: dir).renameExcl
                excl[dirPath] = renameExcl
                out.append(.step(BatchRenameStep(original: item.url, temporary: dir.appending(path: temporaryName(job: job, index: i)),
                                                 target: dir.appending(path: name), identity: id), renameExcl: renameExcl))
            }
            return out
        }) ?? items.map { .skip($0.url, .other(code: EIO, message: String(cString: strerror(EIO)))) }

        var steps: [(step: BatchRenameStep, excl: Bool)] = []
        for b in built {
            switch b {
            case .step(let s, let e): steps.append((s, e))
            case .skip(let u, let reason): ctx.skip(u, reason: reason)
            }
        }
        guard !steps.isEmpty else { return [] }

        let entry = JournalEntry.batchRename(job: job, steps: steps.map(\.step))
        journal: while true {
            do { try await ctx.journalRecord(entry); break journal } catch {
                switch await ctx.resolveFailure(EIO, url: steps[0].step.original) {
                case .retry: continue
                case .skipped, .cancelled:
                    for s in steps.dropFirst() { ctx.skip(s.step.original, reason: .other(code: EIO, message: String(cString: strerror(EIO)))) }
                    return []
                }
            }
        }

        // Phase 1: originals → temporaries.
        var staged: [(step: BatchRenameStep, excl: Bool)] = []
        phase1: for s in steps {
            guard await ctx.checkpoint() else {
                await rollBack(ctx, staged)
                await ctx.journalClear(entry)
                return []
            }
            while true {
                let rc = (try? await ctx.onLane { _ in code(RenamePrimitive.rename(s.step.original.path, s.step.temporary.path, renameExcl: s.excl)) }) ?? EIO
                if rc == 0 { staged.append(s); continue phase1 }
                switch await ctx.resolveFailure(rc, url: s.step.original) {
                case .retry: continue
                case .skipped: continue phase1
                case .cancelled:
                    await rollBack(ctx, staged)
                    await ctx.journalClear(entry)
                    return []
                }
            }
        }
        ctx.fault(.batchRenameStaged)

        // Phase 2: temporaries → targets, never overwriting (a name taken meanwhile gets the next free one).
        var actions: [ItemAction] = []
        for s in staged {
            let landing = (try? await ctx.onLane { _ in land(s.step, renameExcl: s.excl) }) ?? .failed(EIO, at: nil)
            switch landing {
            case .target:
                actions.append(.renamed(from: s.step.original, to: s.step.target, s.step.identity))
                ctx.noteRenamed(from: s.step.original, to: s.step.target)
            case .alternative(let alt):
                ctx.skip(s.step.original, reason: nil)
                actions.append(.renamed(from: s.step.original, to: alt, s.step.identity))
                ctx.noteRenamed(from: s.step.original, to: alt)
            case .failed(let e, let back):
                ctx.skip(s.step.original, reason: FileOpErrorKind(errno: e, isLockedItem: false))
                // Not at its original name (taken, or the folder refuses renames now): record where it is, so Undo
                // can still bring it back.
                let now = back ?? s.step.temporary
                if now != s.step.original {
                    actions.append(.renamed(from: s.step.original, to: now, s.step.identity))
                    ctx.noteRenamed(from: s.step.original, to: now)
                }
            }
            ctx.addProgress(items: 1, current: s.step.target.lastPathComponent)
        }
        await ctx.journalClear(entry)
        return actions
    }

    enum Landing: Sendable, Equatable {
        case target
        case alternative(URL)
        /// Couldn't reach the target; `at` is where the item was put back (its original, or a free name next to it).
        case failed(Int32, at: URL?)
    }

    /// Lane only. temporary → target; on EEXIST the next free name next to the target; on any other failure back to
    /// the original (or the next free name next to it).
    static func land(_ s: BatchRenameStep, renameExcl: Bool) -> Landing {
        assertOffMain()
        switch rename(s.temporary, to: s.target, renameExcl: renameExcl) {
        case .landed(let u): return u == s.target ? .target : .alternative(u)
        case .failed(let e):
            if case .landed(let back) = rename(s.temporary, to: s.original, renameExcl: renameExcl) { return .failed(e, at: back) }
            return .failed(e, at: nil)
        }
    }

    enum Moved: Sendable, Equatable { case landed(URL), failed(Int32) }

    /// Lane only. Renames `from` to `to`, or to `to`'s next free "keep both" name when `to` is taken. Never overwrites.
    static func rename(_ from: URL, to: URL, renameExcl: Bool) -> Moved {
        assertOffMain()
        switch RenamePrimitive.rename(from.path, to.path, renameExcl: renameExcl) {
        case .renamed: return .landed(to)
        case .crossDevice: return .failed(EXDEV)
        case .failed(let e): return .failed(e)
        case .exists: break
        }
        let dir = to.deletingLastPathComponent()
        let isDirectory = PosixFS.info(from.path)?.isDirectory ?? false
        for _ in 0..<1_000 {
            let name = NameGenerator.keepBoth(to.lastPathComponent, isDirectory: isDirectory) { PosixFS.exists(dir.appending(path: $0).path) }
            let alt = dir.appending(path: name)
            switch RenamePrimitive.rename(from.path, alt.path, renameExcl: renameExcl) {
            case .renamed: return .landed(alt)
            case .exists: continue                                  // taken between the check and the rename
            case .crossDevice: return .failed(EXDEV)
            case .failed(let e): return .failed(e)
            }
        }
        return .failed(EEXIST)
    }

    /// Cancel in phase 1: every staged item back to its original name (last staged first).
    static func rollBack(_ ctx: JobContext, _ staged: [(step: BatchRenameStep, excl: Bool)]) async {
        guard !staged.isEmpty else { return }
        let landed: [(URL, URL)] = (try? await ctx.onLane { _ -> [(URL, URL)] in
            var out: [(URL, URL)] = []
            for s in staged.reversed() {
                if case .landed(let u) = rename(s.step.temporary, to: s.step.original, renameExcl: s.excl), u != s.step.original {
                    out.append((s.step.original, u))
                }
            }
            return out
        }) ?? []
        for (original, alt) in landed { ctx.noteRenamed(from: original, to: alt) }
    }

    private static func code(_ outcome: RenameOutcome) -> Int32 {
        switch outcome {
        case .renamed: 0
        case .exists: EEXIST
        case .crossDevice: EXDEV
        case .failed(let e): e
        }
    }

    /// Lane only. Launch recovery of an interrupted batch: items already at their target go back to their temporary
    /// name, then every temporary goes back to its original (or the next free name next to it). A batch that had
    /// finished (every item at its target, no temporary left) is kept. Returns the URLs the items now have.
    static func recover(_ steps: [BatchRenameStep], heartbeat: () -> Void = {}) -> [URL] {
        assertOffMain()
        func atTarget(_ s: BatchRenameStep) -> Bool { FileIdentity.of(path: s.target.path) == s.identity && !PosixFS.exists(s.temporary.path) }
        let finished = steps.allSatisfy(atTarget)
        guard !finished else { return [] }
        for (i, s) in steps.enumerated() where atTarget(s) {
            if i % 256 == 0 { heartbeat() }
            _ = RenamePrimitive.rename(s.target.path, s.temporary.path, renameExcl: true)
        }
        var restored: [URL] = []
        for (i, s) in steps.enumerated() where FileIdentity.of(path: s.temporary.path) == s.identity {
            if i % 256 == 0 { heartbeat() }
            if case .landed(let u) = rename(s.temporary, to: s.original, renameExcl: true) { restored.append(u) }
        }
        return restored
    }
}
