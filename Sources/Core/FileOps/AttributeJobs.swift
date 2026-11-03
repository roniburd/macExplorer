import Foundation
import Darwin
import MacxFS

enum AttributeJobs {
    static let quarantineName = "com.apple.quarantine"

    static func readXattr(_ path: String, _ name: String) -> Data? {
        let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        let read = getxattr(path, name, &buf, size, 0, XATTR_NOFOLLOW)
        return read >= 0 ? Data(buf.prefix(read)) : nil
    }

    /// Lane only. Current values of exactly the fields `edit` touches (nil fields = untouched).
    static func snapshot(_ url: URL, for edit: AttributeEdit) -> AttributeSnapshot? {
        assertOffMain()
        guard let info = PosixFS.info(url.path) else { return nil }
        switch edit {
        case .locked: return AttributeSnapshot(locked: info.flags & UInt32(UF_IMMUTABLE) != 0)
        case .hidden: return AttributeSnapshot(hidden: info.flags & UInt32(UF_HIDDEN) != 0)
        case .extensionHidden:
            let v = try? URL(filePath: url.path).resourceValues(forKeys: [.hasHiddenExtensionKey])
            return AttributeSnapshot(extensionHidden: v?.hasHiddenExtension ?? false)
        case .permissions: return AttributeSnapshot(mode: info.mode)
        case .removeQuarantine: return AttributeSnapshot(quarantine: readXattr(url.path, quarantineName) ?? Data())
        }
    }

    /// Values after applying `edit`. Quarantine `Data()` means "absent".
    static func newValues(_ edit: AttributeEdit) -> AttributeSnapshot {
        switch edit {
        case .locked(let v): AttributeSnapshot(locked: v)
        case .hidden(let v): AttributeSnapshot(hidden: v)
        case .extensionHidden(let v): AttributeSnapshot(extensionHidden: v)
        case .permissions(let m): AttributeSnapshot(mode: m)
        case .removeQuarantine: AttributeSnapshot(quarantine: Data())
        }
    }

    static func apply(_ edit: AttributeEdit, to url: URL) -> Int32 { apply(newValues(edit), to: url) }

    /// Lane only. Applies every non-nil field; unlocks first and locks last so other edits can land.
    static func apply(_ s: AttributeSnapshot, to url: URL) -> Int32 {
        assertOffMain()
        let path = url.path
        func setFlag(_ flag: UInt32, _ on: Bool) -> Int32 {
            guard let i = PosixFS.info(path) else { return ENOENT }
            let flags = on ? i.flags | flag : i.flags & ~flag
            return flags == i.flags || lchflags(path, flags) == 0 ? 0 : errno
        }
        if s.locked == false, case let rc = setFlag(UInt32(UF_IMMUTABLE), false), rc != 0 { return rc }
        if let h = s.hidden, case let rc = setFlag(UInt32(UF_HIDDEN), h), rc != 0 { return rc }
        if let m = s.mode, case let rc = PosixFS.setMode(path, m), rc != 0 { return rc }
        if let e = s.extensionHidden {
            var rv = URLResourceValues(); rv.hasHiddenExtension = e
            var u = URL(filePath: path)
            do { try u.setResourceValues(rv) } catch { return EPERM }
        }
        if let q = s.quarantine {
            if q.isEmpty {
                if removexattr(path, quarantineName, XATTR_NOFOLLOW) != 0 && errno != ENOATTR { return errno }
            } else {
                let rc = q.withUnsafeBytes { setxattr(path, quarantineName, $0.baseAddress, q.count, 0, XATTR_NOFOLLOW) }
                if rc != 0 { return errno }
            }
        }
        if s.locked == true, case let rc = setFlag(UInt32(UF_IMMUTABLE), true), rc != 0 { return rc }
        return 0
    }

    static func setAttributes(_ ctx: JobContext, _ urls: [URL], _ edit: AttributeEdit) async {
        ctx.setTotals(items: urls.count, bytes: 0)
        ctx.setState(.running)
        let new = newValues(edit)
        items: for url in urls {
            guard await ctx.checkpoint() else { break }
            while true {
                let r = (try? await ctx.onLane { _ -> (Int32, AttributeSnapshot?) in
                    guard let old = snapshot(url, for: edit) else { return (ENOENT, nil) }
                    return (apply(edit, to: url), old)
                }) ?? (EIO, nil)
                if r.0 == 0, let old = r.1 {
                    if old != new { ctx.record(.attributesChanged(url, old: old, new: new)) }
                    ctx.noteModified(url)
                    ctx.addProgress(items: 1, current: url.lastPathComponent)
                    continue items
                }
                switch await ctx.resolveFailure(r.0, url: url) {
                case .retry: continue
                case .skipped: continue items
                case .cancelled: return
                }
            }
        }
    }

    /// Children first (reverse pre-order), so a folder never loses x before its contents are done.
    static func chmodRecursive(_ ctx: JobContext, _ url: URL, _ change: ModeChange) async {
        guard let plan = await ctx.plan(sources: [url], destination: nil, mode: .enumerate(noMaterialization: true)),
              let item = plan.items.first else { return }
        struct Change: Sendable { var url: URL; var old: UInt16; var new: UInt16 }
        let changes: [Change] = item.entries.reversed().compactMap { e in
            guard e.type != .symlink, e.type != .other else { return nil }
            if e.type == .directory && !change.applyToDirectories { return nil }
            if e.type == .file && !change.applyToFiles { return nil }
            let new = (e.mode & ~0o777) | (change.mode & 0o777)
            guard new != e.mode else { return nil }
            return Change(url: e.relativePath.isEmpty ? url : url.appending(path: e.relativePath), old: e.mode, new: new)
        }
        let control = ctx.control
        let hook = ctx.tuning.faultHook, jobID = ctx.id
        // One lane call for the whole batch; failures come back for per-item questions. A cancel stops the
        // lane at `applied`: only changes[..<applied] were tried, so only those can be recorded.
        let (applied, failures) = (try? await ctx.onLane { lane -> (Int, [Int: Int32]) in
            var failed: [Int: Int32] = [:]
            for (i, c) in changes.enumerated() {
                if i % 256 == 0 {
                    hook?(.modeBatchCheckpoint, jobID)
                    lane.heartbeat()
                    if !control.laneCheckpoint(lane) { return (i, failed) }
                }
                if case let rc = PosixFS.setMode(c.url.path, c.new), rc != 0 { failed[i] = rc }
            }
            return (changes.count, failed)
        }) ?? (0, [:])
        var asking = true
        for (i, c) in changes[..<applied].enumerated() {
            if var code = failures[i] {
                if control.isCancelled { asking = false }
                guard asking else { continue }
                retry: while true {
                    switch await ctx.resolveFailure(code, url: c.url) {
                    case .retry:
                        code = (try? await ctx.onLane { _ in PosixFS.setMode(c.url.path, c.new) }) ?? EIO
                        if code == 0 { break retry }
                    case .skipped: break retry
                    case .cancelled: asking = false; break retry
                    }
                }
                if code != 0 { continue }
            }
            ctx.record(.modeChanged(c.url, old: c.old, new: c.new))
            ctx.addProgress(items: 1)
        }
        ctx.noteModified(url)
    }
}
