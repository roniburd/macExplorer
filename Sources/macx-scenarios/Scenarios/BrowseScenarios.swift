import Core
import Darwin
import Foundation
import MacxFS

enum BrowseScenarios {
    static let all: [CoreScenario] = [
        CoreScenario("browse.naturalOrderFoldersFirst") { ctx in
            for name in ["file10.txt", "file2.txt", "File3.txt", "file1.txt", "Zeta.txt", "alpha.txt"] { ctx.file(name) }
            ctx.dir("zdir")
            ctx.dir("Adir")
            let m = try await ctx.open(ctx.work)
            try ctx.expectEqual(m.state, .complete, "state")
            try ctx.expectEqual(ctx.names(m), ["Adir", "zdir", "alpha.txt", "file1.txt", "file2.txt", "File3.txt", "file10.txt", "Zeta.txt"],
                                "folders first, then case-insensitive numeric order")
        },
        CoreScenario("browse.hiddenItemsToggle") { ctx in
            ctx.file("visible.txt")
            ctx.file(".dotfile")
            try ctx.setFlags(ctx.file("flagged.txt"), UInt32(UF_HIDDEN))
            let m = try await ctx.open(ctx.work)
            try ctx.expectEqual(ctx.names(m), ["visible.txt"], "dot and UF_HIDDEN items are hidden by default")
            m.setQuery(ViewQuery(showHidden: true))
            try await ctx.waitUntil("hidden rows appear") { Set(ctx.names(m)) == [".dotfile", "flagged.txt", "visible.txt"] }
            m.setQuery(ViewQuery(showHidden: false))
            try await ctx.waitUntil("hidden rows disappear") { ctx.names(m) == ["visible.txt"] }
        },
        CoreScenario("browse.filterFoldsCaseAndDiacritics") { ctx in
            ctx.file("Résumé.pdf")
            ctx.file("resume-old.txt")
            ctx.file("notes.txt")
            let m = try await ctx.open(ctx.work)
            m.setQuery(ViewQuery(filter: "RESUME"))
            try await ctx.waitUntil("filter applied") { Set(ctx.names(m)) == ["Résumé.pdf", "resume-old.txt"] }
            m.setQuery(ViewQuery(filter: "zzz"))
            try await ctx.waitUntil("no matches") { m.rowCount == 0 }
            m.setQuery(ViewQuery())
            try await ctx.waitUntil("filter cleared") { m.rowCount == 3 }
        },
        CoreScenario("browse.errorStates") { ctx in
            let notDirectory = ctx.file("plain.txt")
            let closed = ctx.dir("closed")
            ctx.file("closed/inner.txt")
            try ctx.setMode(closed, 0o000)
            let missing = try await ctx.open(ctx.path("missing"))
            try ctx.expectEqual(missing.state, .error(.notFound), "missing folder")
            let file = try await ctx.open(notDirectory)
            try ctx.expectEqual(file.state, .error(.notADirectory), "file opened as a folder")
            if geteuid() != 0 {
                let denied = try await ctx.open(closed)
                try ctx.expectEqual(denied.state, .error(.permissionPOSIX), "mode-000 folder")
            }
        },
        CoreScenario("browse.rapidNavigationDropsStaleResults", timeout: .seconds(120)) { ctx in
            let big = ctx.flat("big", count: 20_000)
            let small = ctx.dir("small")
            for name in ["a.txt", "b.txt", "c.txt"] { ctx.file("small/\(name)") }
            var last: FolderModel?
            for _ in 0..<20 {
                last?.close()
                let b = ctx.env.makeFolderModel(big, query: ViewQuery())
                b.start()
                b.close()
                let s = ctx.env.makeFolderModel(small, query: ViewQuery())
                ctx.track(s)
                s.start()
                last = s
                await Task.yield()
            }
            let final = try ctx.unwrap(last, "final model")
            try await ctx.waitUntil("small folder completes", timeout: .seconds(10)) { final.state == .complete }
            try await Task.sleep(for: .milliseconds(300))
            try ctx.expectEqual(ctx.names(final), ["a.txt", "b.txt", "c.txt"], "only the small folder's rows")
            let fresh = try await ctx.open(small, timeout: .seconds(3))
            try ctx.expectEqual(fresh.state, .complete, "lanes still healthy after 20 cancelled reads")
        },
    ]
}
