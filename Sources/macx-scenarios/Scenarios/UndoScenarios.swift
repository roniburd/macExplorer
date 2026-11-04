import Core
import Foundation

enum UndoScenarios {
    static let all: [CoreScenario] = [
        CoreScenario("undo.copyTrashesCreatedItems") { ctx in
            let a = ctx.file("a.txt")
            _ = await ctx.perform(.copy(sources: [a], destination: ctx.dir("dst")))
            _ = try await ctx.undo()
            try ctx.expect(!ctx.exists(ctx.path("dst/a.txt")) && ctx.exists(a), "copy undone, source untouched")
        },
        CoreScenario("undo.moveMovesBackAndRedoMovesAgain") { ctx in
            let a = ctx.file("src/a.txt")
            let dst = ctx.dir("dst")
            _ = await ctx.perform(.move(sources: [a], destination: dst))
            _ = try await ctx.undo()
            try ctx.expect(ctx.exists(a) && !ctx.exists(ctx.path("dst/a.txt")), "moved back")
            _ = try await ctx.redo()
            try ctx.expect(!ctx.exists(a) && ctx.exists(ctx.path("dst/a.txt")), "redo moved it again")
        },
        CoreScenario("undo.renameRenamesBack") { ctx in
            let a = ctx.file("a.txt")
            _ = await ctx.perform(.rename(a, to: "b.txt"))
            _ = try await ctx.undo()
            try ctx.expectEqual(ctx.entries(ctx.work), ["a.txt"], "renamed back")
        },
        CoreScenario("undo.trashRestoresOriginalPath") { ctx in
            let a = ctx.file("a.txt", "keep me")
            _ = await ctx.perform(.trash([a]))
            try ctx.expect(!ctx.exists(a), "trashed")
            _ = try await ctx.undo()
            try ctx.expectEqual(ctx.size(a), 7, "restored to the original path with its data")
        },
        CoreScenario("undo.newFolderRemovesIt") { ctx in
            _ = await ctx.perform(.newItem(.folder, in: ctx.work))
            _ = try await ctx.undo()
            try ctx.expect(!ctx.exists(ctx.path("New Folder")), "new folder undone")
        },
        CoreScenario("undo.replaceRestoresDisplacedItem") { ctx in
            let src = ctx.file("src/a.txt", "hello")
            ctx.file("dst/a.txt", "x")
            ctx.setInteraction(ScriptedInteraction(conflicts: [.one(.replace)]))
            _ = await ctx.perform(.copy(sources: [src], destination: ctx.path("dst")))
            _ = try await ctx.undo()
            try ctx.expectEqual(ctx.size(ctx.path("dst/a.txt")), 1, "the replaced original is back")
        },
        CoreScenario("undo.chmodRestoresModes") { ctx in
            let d = ctx.dir("d")
            let f = ctx.file("d/f.txt")
            try ctx.setMode(f, 0o644)
            try ctx.setMode(d, 0o755)
            _ = await ctx.perform(.chmodRecursive(d, ModeChange(mode: 0o700)))
            _ = try await ctx.undo()
            try ctx.expectEqual(ctx.mode(f), 0o644, "file mode restored")
            try ctx.expectEqual(ctx.mode(d), 0o755, "folder mode restored")
        },
        CoreScenario("undo.skipsItemsChangedExternally") { ctx in
            let a = ctx.file("src/a.txt")
            _ = await ctx.perform(.move(sources: [a], destination: ctx.dir("dst")))
            try ctx.removeRaw(ctx.path("dst/a.txt"))        // gone behind our back
            let undo = try await ctx.undo()
            try ctx.expectEqual(undo.skipped.count, 1, "the vanished item is listed in the summary")
            try ctx.expect(!ctx.exists(a), "nothing resurrected")
        },
        CoreScenario("undo.partialJobUndoesDoneItemsOnly") { ctx in
            let a = ctx.file("a.txt")
            _ = await ctx.perform(.copy(sources: [a, ctx.path("missing.txt")], destination: ctx.dir("dst")))
            _ = try await ctx.undo()
            try ctx.expect(!ctx.exists(ctx.path("dst/a.txt")) && ctx.exists(a), "only the copied item was undone")
        },
    ]
}
