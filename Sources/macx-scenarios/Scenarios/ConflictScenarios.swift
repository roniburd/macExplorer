import Core
import Foundation

enum ConflictScenarios {
    static func replacedTrashURL(_ out: JobOutcome) -> URL? {
        out.record.actions.lazy.compactMap { action -> URL? in
            if case .replaced(_, let trashURL, _) = action { return trashURL }
            return nil
        }.first
    }

    static let all: [CoreScenario] = [
        CoreScenario("conflict.replaceTrashesExisting") { ctx in
            let src = ctx.file("src/a.txt", "hello")
            ctx.file("dst/a.txt", "x")
            let script = ScriptedInteraction(conflicts: [.one(.replace)])
            ctx.setInteraction(script)
            let out = await ctx.perform(.copy(sources: [src], destination: ctx.path("dst")))
            try ctx.expectEqual(script.askedConflicts().count, 1, "one conflict asked")
            try ctx.expectEqual(ctx.size(ctx.path("dst/a.txt")), 5, "destination replaced by the source")
            let trashURL = try ctx.unwrap(replacedTrashURL(out), "recorded .replaced action")
            try ctx.expectEqual(ctx.size(trashURL), 1, "displaced item kept in the trash, recoverable")
        },
        CoreScenario("conflict.skipLeavesDestination") { ctx in
            let src = ctx.file("src/a.txt", "hello")
            ctx.file("dst/a.txt", "x")
            ctx.setInteraction(ScriptedInteraction(conflicts: [.one(.skip)]))
            let out = await ctx.perform(.copy(sources: [src], destination: ctx.path("dst")))
            try ctx.expectEqual(ctx.size(ctx.path("dst/a.txt")), 1, "destination untouched")
            try ctx.expect(out.skipped.contains { $0.url.lastPathComponent == "a.txt" && $0.reason == nil }, "skip recorded: \(out.skipped)")
        },
        CoreScenario("conflict.keepBoth") { ctx in
            let src = ctx.file("src/a.txt", "hello")
            ctx.file("dst/a.txt", "x")
            ctx.setInteraction(ScriptedInteraction(conflicts: [.one(.keepBoth)]))
            _ = await ctx.perform(.copy(sources: [src], destination: ctx.path("dst")))
            try ctx.expectEqual(ctx.entries(ctx.path("dst")), ["a.txt", "a 2.txt"], "next free name")
            try ctx.expectEqual(ctx.size(ctx.path("dst/a 2.txt")), 5, "the new copy holds the source data")
        },
        CoreScenario("conflict.mergeFolders") { ctx in
            ctx.file("src/F/x.txt", "src-x")
            ctx.file("src/F/y.txt", "src-y")
            ctx.file("dst/F/y.txt", "d")
            ctx.file("dst/F/z.txt", "dst-z")
            let script = ScriptedInteraction(conflicts: [.one(.merge), .one(.replace)])
            ctx.setInteraction(script)
            _ = await ctx.perform(.move(sources: [ctx.path("src/F")], destination: ctx.path("dst")))
            try ctx.expect(script.askedConflicts().first?.isFolderMerge == true, "first question is a folder merge")
            try ctx.expectEqual(ctx.entries(ctx.path("dst/F")), ["x.txt", "y.txt", "z.txt"], "merged contents")
            try ctx.expectEqual(ctx.size(ctx.path("dst/F/y.txt")), 5, "conflicting child replaced")
            try ctx.expect(!ctx.exists(ctx.path("src/F")), "emptied source folder removed after the merge")
        },
        CoreScenario("conflict.applyToAllAsksOnce") { ctx in
            for n in ["a", "b", "c"] {
                ctx.file("src/\(n).txt", "new")
                ctx.file("dst/\(n).txt", "o")
            }
            let script = ScriptedInteraction(conflicts: [.all(.keepBoth)])
            ctx.setInteraction(script)
            _ = await ctx.perform(.copy(sources: ["a", "b", "c"].map { ctx.path("src/\($0).txt") }, destination: ctx.path("dst")))
            try ctx.expectEqual(script.askedConflicts().count, 1, "asked once")
            try ctx.expectEqual(ctx.entries(ctx.path("dst")), ["a.txt", "b.txt", "c.txt", "a 2.txt", "b 2.txt", "c 2.txt"], "kept both for all")
        },
        CoreScenario("conflict.perItemFromCompare") { ctx in
            let a = ctx.file("src/a.txt", "new")
            let b = ctx.file("src/b.txt", "new")
            ctx.file("dst/a.txt", "o")
            ctx.file("dst/b.txt", "o")
            ctx.setInteraction(ScriptedInteraction(conflicts: [.perItem([a: .replace])]))   // b missing → skip
            _ = await ctx.perform(.copy(sources: [a, b], destination: ctx.path("dst")))
            try ctx.expectEqual(ctx.size(ctx.path("dst/a.txt")), 3, "a replaced")
            try ctx.expectEqual(ctx.size(ctx.path("dst/b.txt")), 1, "b skipped (absent from the per-item map)")
        },
        CoreScenario("conflict.cancelJobStops") { ctx in
            let a = ctx.file("src/a.txt", "new")
            let b = ctx.file("src/b.txt", "new")
            ctx.file("dst/a.txt", "o")
            ctx.setInteraction(ScriptedInteraction(conflicts: [.cancelJob]))
            let out = await ctx.perform(.copy(sources: [a, b], destination: ctx.path("dst")))
            try ctx.expect(out.wasCancelled, "job cancelled from the conflict dialog")
            try ctx.expectEqual(ctx.size(ctx.path("dst/a.txt")), 1, "existing item untouched")
            try ctx.expect(!ctx.exists(ctx.path("dst/b.txt")), "later items not copied")
        },
    ]
}
