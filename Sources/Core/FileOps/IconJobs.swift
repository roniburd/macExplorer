import Foundation
import Darwin
import MacxFS

/// `.setCustomIcon` jobs and their undo step (P4-07). Only items whose stored icon actually changes are recorded.
/// The recorded `new` is what the writer reads back after writing (macOS re-encodes a PNG as ICNS), so undo and redo
/// compare against what is really stored.
enum IconJobs {
    static let notAnImage = FileOpErrorKind.other(code: EINVAL, message: "not an image")
    /// The writer refuses symlinks (ENOTSUP): skipped with this reason, no question (Retry could never help).
    static let symlinkRefused = FileOpErrorKind(errno: ENOTSUP, isLockedItem: false)
    /// The item is marked as having a custom icon that can't be read: setting a new one is skipped with this reason,
    /// because Undo couldn't restore the original. Remove Custom Icon still works.
    static let unreadableIcon = FileOpErrorKind.other(code: EFTYPE, message: "its current custom icon can't be read, so Undo couldn't restore it (remove it first)")

    static func setCustomIcon(_ ctx: JobContext, _ urls: [URL], _ data: IconImageData?) async {
        ctx.setTotals(items: urls.count, bytes: 0)
        ctx.setState(.running)
        if let data, !data.isDecodableImage {
            // Checked before any item is touched: one question, then every item is skipped (or the job cancelled).
            let answer = await ctx.askError(FileOpError(kind: notAnImage, url: urls.first ?? URL(filePath: "/")))
            if answer == .cancel { ctx.cancelJob(); return }
            for u in urls { ctx.skip(u, reason: notAnImage) }
            return
        }
        let writer = ctx.iconWriter
        struct Step: Sendable {
            var code: Int32
            var changed = false
            var previous: IconImageData? = nil
            var stored: IconImageData? = nil
            var unreadable = false
        }
        // One copy of each distinct icon in the record: the read-back of the same image dropped on many items is
        // the same bytes every time (multi-MB ICNS), so the undo record keeps one buffer, not one per item.
        _ = ctx.shareIcon(data)
        items: for url in urls {
            guard await ctx.checkpoint() else { break }
            while true {
                let r = (try? await ctx.onLane { _ -> Step in
                    do {
                        let before = try writer.storedCustomIcon(url)
                        switch (before, data) {
                        case (.none, nil): return Step(code: 0)                       // nothing to remove: leave it alone
                        case (.unreadable, .some):
                            // Replacing it would lose the original for good: Undo could never put it back.
                            return Step(code: 0, unreadable: true)
                        case (.unreadable, nil):
                            // The item is marked as having a custom icon: Remove clears the mark (the writer leaves an
                            // unparseable fork alone). Nothing readable to keep for Undo, which leaves the item as it is.
                            try writer.setIcon(nil, for: url)
                            return Step(code: 0, changed: true)
                        case (.none, .some), (.image, _):
                            try writer.setIcon(data, for: url)
                            let stored = data == nil ? nil : ((try? writer.currentCustomIcon(url)) ?? data)
                            let previous = before.image
                            return Step(code: 0, changed: previous != stored, previous: previous, stored: stored)
                        }
                    } catch { return Step(code: (error as? any ErrnoCarrying)?.errnoCode ?? EIO) }
                }) ?? Step(code: EIO)
                if r.code == 0 {
                    if r.unreadable {
                        ctx.skip(url, reason: unreadableIcon)
                        continue items
                    }
                    if r.changed {
                        ctx.record(.customIconChanged(url, previous: ctx.shareIcon(r.previous), new: ctx.shareIcon(r.stored)))
                        ctx.noteModified(url)
                    }
                    ctx.addProgress(items: 1, current: url.lastPathComponent)
                    continue items
                }
                if r.code == ENOTSUP {
                    ctx.skip(url, reason: symlinkRefused)
                    continue items
                }
                switch await ctx.resolveFailure(r.code, url: url) {
                case .retry: continue
                case .skipped: continue items
                case .cancelled: return
                }
            }
        }
    }

    /// Undo/redo step: writes `restore` only while the item still shows `expected` (`IconCompare.sameImage`);
    /// records the inverse so redo undoes the undo.
    static func restoreIcon(_ ctx: JobContext, _ url: URL, expected: IconImageData?, restore: IconImageData?) async -> StepResult {
        enum Check: Sendable { case gone, changed, failed(Int32), written(current: IconImageData?, stored: IconImageData?) }
        let writer = ctx.iconWriter
        while true {
            let r = (try? await ctx.onLane { _ -> Check in
                guard PosixFS.exists(url.path) else { return .gone }
                let onDisk: StoredCustomIcon
                do { onDisk = try writer.storedCustomIcon(url) } catch {
                    let code = (error as? any ErrnoCarrying)?.errnoCode ?? EIO
                    return code == ENOENT ? .gone : .failed(code)
                }
                // An unreadable icon was put there by someone else: never written over (it could not be put back).
                guard onDisk != .unreadable else { return .changed }
                let current = onDisk.image
                guard IconCompare.sameImage(current, expected) else { return .changed }
                if current == nil && restore == nil { return .written(current: nil, stored: nil) }
                do { try writer.setIcon(restore, for: url) } catch { return .failed((error as? any ErrnoCarrying)?.errnoCode ?? EIO) }
                let stored = restore == nil ? nil : ((try? writer.currentCustomIcon(url)) ?? restore)
                return .written(current: current, stored: stored)
            }) ?? .failed(EIO)
            switch r {
            case .gone:
                ctx.skip(url, reason: .sourceGone)
                return .skipped
            case .changed:
                ctx.skip(url, reason: .changedDuringMove)
                return .skipped
            case .written(let current, let stored):
                ctx.record(.customIconChanged(url, previous: ctx.shareIcon(current), new: ctx.shareIcon(stored)))
                ctx.noteModified(url)
                return .done
            case .failed(let code):
                switch await ctx.resolveFailure(code, url: url) {
                case .retry: continue
                case .skipped: return .skipped
                case .cancelled: return .cancelled
                }
            }
        }
    }
}

/// Keeps one buffer per distinct icon image seen by a job (byte-equal data reuses the first copy). Bounded: only the
/// last few distinct images are compared against.
struct IconShare: Sendable {
    static let limit = 4
    private var seen: [IconImageData] = []

    @discardableResult
    mutating func note(_ icon: IconImageData?) -> IconImageData? {
        guard let icon else { return nil }
        if let index = seen.firstIndex(where: { $0.bytes.count == icon.bytes.count && $0.bytes == icon.bytes }) {
            let match = seen.remove(at: index)
            seen.append(match)
            return match
        }
        seen.append(icon)
        if seen.count > Self.limit { seen.removeFirst() }
        return icon
    }
}
