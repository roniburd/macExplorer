import Core
import Darwin
import Foundation
import MacxFS

@MainActor final class ChangeCounter {
    private(set) var structural = 0
    private(set) var reloads = 0
    func add(_ set: ChangeSet) {
        for change in set.changes {
            switch change {
            case .insert, .remove, .move, .reset: structural += 1
            case .reload: reloads += 1
            }
        }
    }
}

@MainActor final class RelocationBox { var value: (URL, RelocationReason)? }

enum WatcherScenarios {
    static func createEmptyFiles(_ paths: [String]) {
        for path in paths {
            let fd = open(path, O_CREAT | O_WRONLY | O_EXCL, 0o644)
            if fd >= 0 { close(fd) }
        }
    }

    static let all: [CoreScenario] = [
        CoreScenario("watch.burst10kKeepsSelection", timeout: .seconds(120)) { ctx in
            ctx.file("keep.txt")
            let m = try await ctx.open(ctx.work)
            m.select(.names(["keep.txt"]))
            let id = m.identity(atRow: try ctx.unwrap(m.row(named: "keep.txt"), "row of keep.txt"))
            let paths = (0..<10_000).map { ctx.path(String(format: "burst-%05d.txt", $0)).path }
            await ctx.background { createEmptyFiles(paths) }
            try await ctx.waitUntil("model reaches 10,001 rows", timeout: .seconds(60)) { m.rowCount == 10_001 }
            let fresh = try await ctx.open(ctx.work)
            try ctx.expectEqual(ctx.names(m), ctx.names(fresh), "watched model equals a fresh read")
            try ctx.expect(m.selection.ids == [id], "selection kept by identity")
            try ctx.expectEqual(m.selectedURLs.map(\.lastPathComponent), ["keep.txt"], "selected row is still keep.txt")
        },
        CoreScenario("watch.atomicSaveKeepsSelection") { ctx in
            ctx.file("doc.txt", "v1")
            ctx.file("other.txt")
            let m = try await ctx.open(ctx.work)
            m.select(.names(["doc.txt"]))
            let temporary = ctx.file(".doc.txt.tmp", "version-2")
            try ctx.renameRaw(temporary, to: ctx.path("doc.txt"))
            try await ctx.waitUntil("model sees the new size") {
                m.row(named: "doc.txt").map { m.entry(atRow: $0).size == 9 } ?? false
            }
            try ctx.expectEqual(m.selectedURLs.map(\.lastPathComponent), ["doc.txt"], "selection survives an atomic save")
        },
        CoreScenario("watch.externalRenameAndDelete") { ctx in
            ctx.file("b.txt")
            ctx.file("d.txt")
            ctx.file("e.txt")
            let m = try await ctx.open(ctx.work)
            try ctx.renameRaw(ctx.path("b.txt"), to: ctx.path("c.txt"))
            try ctx.removeRaw(ctx.path("d.txt"))
            try await ctx.waitUntil("rename and delete applied") { ctx.names(m) == ["c.txt", "e.txt"] }
        },
        CoreScenario("watch.subfolderChangesCauseNoReread") { ctx in
            ctx.dir("sub")
            ctx.file("top.txt")
            let m = try await ctx.open(ctx.work)
            let counter = ChangeCounter()
            ctx.keep(m.observe { if case .changes(let set) = $0 { counter.add(set) } })
            for i in 0..<50 { ctx.file("sub/n\(i).txt") }
            try await Task.sleep(for: .milliseconds(800))
            try ctx.expectEqual(counter.structural, 0, "events inside a subfolder must not insert/remove/reset rows")
            try ctx.expectEqual(m.rowCount, 2, "row count unchanged")
        },
        CoreScenario("watch.removedFolderRelocatesToParent") { ctx in
            ctx.file("sub/x.txt")
            let m = try await ctx.open(ctx.path("sub"))
            let box = RelocationBox()
            ctx.keep(m.observe { if case .relocate(let to, let reason) = $0 { box.value = (to, reason) } })
            try ctx.removeTreeRaw(ctx.path("sub"))
            try await ctx.waitUntil("relocate event") { box.value != nil }
            try ctx.expectEqual(box.value?.0.standardizedFileURL.path, ctx.work.standardizedFileURL.path, "nearest existing ancestor")
            try ctx.expectEqual(box.value?.1, .movedOrDeleted(name: "sub"), "banner reason")
        },
        CoreScenario("watch.changesDuringEnumerationNotLost", timeout: .seconds(120)) { ctx in
            let big = ctx.flat("big", count: 20_000)
            let late = ctx.path("big/zz-late.txt").path
            let m = ctx.env.makeFolderModel(big, query: ViewQuery())
            ctx.track(m)
            m.start()
            await ctx.background { createEmptyFiles([late]) }
            try await ctx.waitUntil("complete with the late file", timeout: .seconds(60)) {
                m.state == .complete && m.row(named: "zz-late.txt") != nil
            }
            try ctx.expectEqual(m.rowCount, 20_001, "no entry lost or duplicated")
        },
    ]
}
