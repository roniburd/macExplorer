import Foundation
import Darwin
import MacxFS

enum CreateOps {
    static func newItem(_ ctx: JobContext, kind: NewItemKind, in directory: URL) async {
        ctx.setTotals(items: 1, bytes: 0)
        ctx.setState(.running)
        while true {
            let result = (try? await ctx.onLane { _ -> (Int32, URL?, FileIdentity?) in
                for _ in 0..<1_000 {
                    let name = NameGenerator.newItemName(kind) { PosixFS.exists(directory.appending(path: $0).path) }
                    let u = directory.appending(path: name, directoryHint: kind == .folder ? .isDirectory : .notDirectory)
                    let rc: Int32
                    if kind == .folder {
                        rc = mkdir(u.path, 0o777) == 0 ? 0 : errno
                    } else {
                        let fd = open(u.path, O_CREAT | O_EXCL | O_WRONLY, 0o666)
                        rc = fd >= 0 ? 0 : errno
                        if fd >= 0 { close(fd) }
                    }
                    if rc == EEXIST { continue }               // lost a race with another process; next name
                    return (rc, rc == 0 ? u : nil, rc == 0 ? FileIdentity.of(path: u.path) : nil)
                }
                return (EEXIST, nil, nil)
            }) ?? (EIO, nil, nil)
            if result.0 == 0, let url = result.1, let id = result.2 {
                ctx.record(.created(url, id))
                ctx.landed(url, select: true, beginRename: true)
                ctx.addProgress(items: 1, current: url.lastPathComponent)
                return
            }
            switch await ctx.resolveFailure(result.0, url: directory) {
            case .retry: continue
            case .skipped, .cancelled: return
            }
        }
    }

    static func rename(_ ctx: JobContext, _ url: URL, to newName: String) async {
        ctx.setTotals(items: 1, bytes: 0)
        ctx.setState(.running)
        if newName.isEmpty || newName.contains("/") || newName.utf8.count > 255 {
            let kind: FileOpErrorKind = newName.utf8.count > 255 ? .nameTooLong
                : .other(code: EINVAL, message: String(cString: strerror(EINVAL)))
            if await ctx.askError(FileOpError(kind: kind, url: url)) == .cancel { ctx.cancelJob() } else { ctx.skip(url, reason: kind) }
            return
        }
        guard url.lastPathComponent != newName else { return }
        let target = url.deletingLastPathComponent().appending(path: newName)
        let parent = url.deletingLastPathComponent()
        let caps = (try? await ctx.onLane { _ in VolumeIdentity.capabilities(of: parent) })
            ?? VolumeIdentity.Capabilities(clone: false, renameExcl: false, caseSensitive: false)
        let result: StepResult
        if RenamePrimitive.isSameItemRename(url.lastPathComponent, newName, caseSensitive: caps.caseSensitive) {
            result = await inPlace(ctx, from: url, to: target)
        } else {
            result = await ctx.attempt(url, destination: target) { _ in
                switch RenamePrimitive.rename(url.path, target.path, renameExcl: caps.renameExcl) {
                case .renamed: 0
                case .exists: EEXIST
                case .crossDevice: EXDEV
                case .failed(let e): e
                }
            }
        }
        guard result == .done else { return }
        let id = (try? await ctx.onLane { _ in FileIdentity.of(path: target.path) }) ?? nil
        if let id { ctx.record(.renamed(from: url, to: target, id)) }
        ctx.noteRenamed(from: url, to: target)
        ctx.addProgress(items: 1, current: newName)
    }

    private static func inPlace(_ ctx: JobContext, from: URL, to: URL) async -> StepResult {
        while true {
            let r = (try? await ctx.onLane { _ in RenamePrimitive.renameInPlace(from.path, to.path) }) ?? .failed(EIO)
            switch r {
            case .applied: return .done
            case .needsTwoStep: return await twoStepRename(ctx, from: from, to: to)
            case .failed(let e):
                switch await ctx.resolveFailure(e, url: from, destination: to) {
                case .retry: continue
                case .skipped: return .skipped
                case .cancelled: return .cancelled
                }
            }
        }
    }

    /// from → temp → target, journaled first so LaunchRecovery can restore `from` after a crash.
    static func twoStepRename(_ ctx: JobContext, from: URL, to: URL) async -> StepResult {
        let temp = from.deletingLastPathComponent()
            .appending(path: ".\(UUID().uuidString.prefix(8).lowercased()).macx-rename-\(ctx.id.short)")
        let entry = JournalEntry.twoStepRename(job: ctx.id, temporary: temp, original: from, target: to)
        do { try await ctx.journalRecord(entry) } catch {
            _ = await ctx.resolveFailure(EIO, url: from, destination: to)
            return .skipped
        }
        let r = await ctx.attempt(from, destination: to) { _ in
            let first = PosixFS.rename(from.path, temp.path)
            guard first == 0 else { return first }
            let second = PosixFS.rename(temp.path, to.path)
            if second != 0 { _ = PosixFS.rename(temp.path, from.path) }
            return second
        }
        await ctx.journalClear(entry)
        return r
    }
}
