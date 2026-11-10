import Foundation
import Darwin
import MacxFS

/// `.setTags` jobs and their undo step. Only items whose tags actually change are recorded.
enum TagJobs {
    static func setTags(_ ctx: JobContext, _ urls: [URL], _ edit: TagEdit) async {
        ctx.setTotals(items: urls.count, bytes: 0)
        ctx.setState(.running)
        var edit = edit
        if case .toggle(let tag) = edit {
            // Finder semantics: if any item lacks the tag, add it everywhere; otherwise remove it everywhere.
            let name = tag.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let allHave = (try? await ctx.onLane { _ in
                urls.allSatisfy { u in ((try? TagIO.read(u)) ?? []).contains { $0.name.lowercased() == name } }
            }) ?? false
            edit = allHave ? .remove(tag.name) : .add(tag)
        }
        let resolved = edit
        struct Step: Sendable { var code: Int32; var old: [FileTag] = []; var new: [FileTag] = [] }
        items: for url in urls {
            guard await ctx.checkpoint() else { break }
            while true {
                let r = (try? await ctx.onLane { _ -> Step in
                    do throws(TagIOError) {
                        let old = try TagIO.read(url)
                        let new = resolved.applied(to: old)
                        if new != old { try TagIO.write(new, to: url) }
                        return Step(code: 0, old: old, new: new)
                    } catch { return Step(code: error.code) }
                }) ?? Step(code: EIO)
                if r.code == 0 {
                    if r.old != r.new {
                        ctx.record(.tagsChanged(url, old: r.old, new: r.new))
                        ctx.noteModified(url)
                    }
                    ctx.addProgress(items: 1, current: url.lastPathComponent)
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

    /// Undo/redo step: writes `restore` only while the item still has `expected` (compared after `normalize`);
    /// records the inverse so redo undoes the undo.
    static func restoreTags(_ ctx: JobContext, _ url: URL, expected: [FileTag], restore: [FileTag]) async -> StepResult {
        enum Check: Sendable { case gone, changed, written(Int32) }
        while true {
            let r = (try? await ctx.onLane { _ -> Check in
                guard PosixFS.exists(url.path) else { return .gone }
                let current: [FileTag]
                do throws(TagIOError) { current = try TagIO.read(url) } catch { return error.code == ENOENT ? .gone : .written(error.code) }
                guard TagIO.normalize(current) == TagIO.normalize(expected) else { return .changed }
                do throws(TagIOError) { try TagIO.write(restore, to: url); return .written(0) } catch { return .written(error.code) }
            }) ?? .written(EIO)
            switch r {
            case .gone:
                ctx.skip(url, reason: .sourceGone)
                return .skipped
            case .changed:
                ctx.skip(url, reason: .changedDuringMove)
                return .skipped
            case .written(0):
                ctx.record(.tagsChanged(url, old: expected, new: restore))
                ctx.noteModified(url)
                return .done
            case .written(let code):
                switch await ctx.resolveFailure(code, url: url) {
                case .retry: continue
                case .skipped: return .skipped
                case .cancelled: return .cancelled
                }
            }
        }
    }
}
