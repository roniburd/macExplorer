import Core
import Foundation

enum ClipboardScenarios {
    static let all: [CoreScenario] = [
        CoreScenario("clip.copyThenPasteCopies") { ctx in
            let clipboard = Clipboard(backend: InMemoryPasteboard())
            let a = ctx.file("a.txt")
            let dst = ctx.dir("dst")
            clipboard.copy([a])
            let plan = try ctx.unwrap(clipboard.pastePlan(into: dst, moveItemHere: false), "paste plan")
            try ctx.expectEqual(plan.operation, .copy, "copy then paste copies")
            _ = await ctx.perform(.copy(sources: plan.sources, destination: plan.destination))
            try ctx.expect(ctx.exists(a) && ctx.exists(ctx.path("dst/a.txt")), "copied, source kept")
        },
        CoreScenario("clip.cutThenPasteMoves") { ctx in
            let clipboard = Clipboard(backend: InMemoryPasteboard())
            let a = ctx.file("a.txt")
            let dst = ctx.dir("dst")
            clipboard.cut([a])
            try ctx.expectEqual(clipboard.cutNames(in: ctx.work), ["a.txt"], "cut item marked for dimming")
            let plan = try ctx.unwrap(clipboard.pastePlan(into: dst, moveItemHere: false), "paste plan")
            try ctx.expectEqual(plan.operation, .move, "valid cut marker moves")
            _ = await ctx.perform(.move(sources: plan.sources, destination: plan.destination))
            clipboard.didPaste(plan)
            try ctx.expect(clipboard.cutURLs.isEmpty, "cut state cleared after the move")
            try ctx.expect(clipboard.pastePlan(into: ctx.work, moveItemHere: false) == nil,
                           "a used-up cut leaves nothing to paste (no copy of the moved-away path)")
            try ctx.expect(!ctx.exists(a) && ctx.exists(ctx.path("dst/a.txt")), "moved")
        },
        CoreScenario("clip.staleCutPastesAsCopy") { ctx in
            let board = InMemoryPasteboard()
            let clipboard = Clipboard(backend: board)
            let a = ctx.file("a.txt")
            clipboard.cut([a])
            board.simulateExternalCopy([a])
            clipboard.revalidate()
            let plan = try ctx.unwrap(clipboard.pastePlan(into: ctx.dir("dst"), moveItemHere: false), "paste plan")
            try ctx.expectEqual(plan.operation, .copy, "changeCount moved on: the marker no longer counts")
            try ctx.expect(clipboard.cutURLs.isEmpty, "nothing shown as cut")
        },
        CoreScenario("clip.cutPasteIntoSameFolderIsNoOp") { ctx in
            let clipboard = Clipboard(backend: InMemoryPasteboard())
            clipboard.cut([ctx.file("a.txt")])
            let plan = try ctx.unwrap(clipboard.pastePlan(into: ctx.work, moveItemHere: false), "paste plan")
            try ctx.expect(plan.isNoOp, "cut-paste into the items' own folder does nothing")
        },
        CoreScenario("clip.moveItemHereMovesExternalCopy") { ctx in
            let board = InMemoryPasteboard()
            let clipboard = Clipboard(backend: board)
            let a = ctx.file("a.txt")
            board.simulateExternalCopy([a])            // "Finder copied a.txt"
            let plan = try ctx.unwrap(clipboard.pastePlan(into: ctx.dir("dst"), moveItemHere: true), "paste plan")
            try ctx.expectEqual(plan.operation, .move, "⌥⌘V moves whatever file URLs are on the pasteboard")
        },
        CoreScenario("clip.escapeClearsMarkerKeepsURLs") { ctx in
            let board = InMemoryPasteboard()
            let clipboard = Clipboard(backend: board)
            clipboard.cut([ctx.file("a.txt")])
            clipboard.clearCut()
            try ctx.expect(!board.hasCutMarker() && board.hasFileURLs(), "marker removed, URLs kept")
            try ctx.expect(clipboard.cutURLs.isEmpty, "dimming cleared")
            let plan = try ctx.unwrap(clipboard.pastePlan(into: ctx.dir("dst"), moveItemHere: false), "paste plan")
            try ctx.expectEqual(plan.operation, .copy, "after Esc the paste copies")
        },
    ]
}
