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
        struct Step: Sendable { var code: Int32; var previous: IconImageData? = nil; var stored: IconImageData? = nil }
        items: for url in urls {
            guard await ctx.checkpoint() else { break }
            while true {
                let r = (try? await ctx.onLane { _ -> Step in
                    do {
                        let previous = try writer.currentCustomIcon(url)
                        if previous == nil && data == nil { return Step(code: 0) }     // nothing to remove: leave it alone
                        try writer.setIcon(data, for: url)
                        let stored = data == nil ? nil : ((try? writer.currentCustomIcon(url)) ?? data)
                        return Step(code: 0, previous: previous, stored: stored)
                    } catch { return Step(code: (error as? any ErrnoCarrying)?.errnoCode ?? EIO) }
                }) ?? Step(code: EIO)
                if r.code == 0 {
                    if r.previous != r.stored {
                        ctx.record(.customIconChanged(url, previous: r.previous, new: r.stored))
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
                let current: IconImageData?
                do { current = try writer.currentCustomIcon(url) } catch {
                    let code = (error as? any ErrnoCarrying)?.errnoCode ?? EIO
                    return code == ENOENT ? .gone : .failed(code)
                }
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
                ctx.record(.customIconChanged(url, previous: current, new: stored))
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
