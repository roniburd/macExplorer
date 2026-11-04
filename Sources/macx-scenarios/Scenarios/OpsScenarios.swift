import Core
import Darwin
import Foundation
import MacxFS

enum OpsScenarios {
    static let all: [CoreScenario] = [
        CoreScenario("ops.copyTreeWithSymlink") { ctx in
            ctx.file("src/a.txt", "hello")
            ctx.file("src/d/b.txt")
            ctx.dir("src/d/e")
            try ctx.symlink("src/link", to: "a.txt")
            let dst = ctx.dir("dst")
            let m = try await ctx.open(dst)
            let out = await ctx.perform(.copy(sources: [ctx.path("src/a.txt"), ctx.path("src/d"), ctx.path("src/link")], destination: dst))
            try ctx.expect(out.skipped.isEmpty, "nothing skipped: \(out.skipped)")
            try ctx.expectEqual(ctx.size(ctx.path("dst/a.txt")), 5, "a.txt copied")
            try ctx.expect(ctx.exists(ctx.path("dst/d/b.txt")) && ctx.isDirectory(ctx.path("dst/d/e")), "tree copied")
            try ctx.expectEqual(ctx.readLink(ctx.path("dst/link")), "a.txt", "symlink copied as a link")
            try ctx.expect(ctx.exists(ctx.path("src/a.txt")), "source kept")
            try await ctx.waitUntil("destination model shows the new rows") { Set(ctx.names(m)) == ["d", "a.txt", "link"] }
        },
        CoreScenario("ops.copyPreservesMetadata") { ctx in
            let doc = ctx.file("src/doc.txt", "data")
            try ctx.setXattr(doc, "com.macexplorer.test", "v1")
            try ctx.setMode(doc, 0o640)
            try ctx.setModificationDate(doc, Date(timeIntervalSince1970: 1_000_000_000))
            let readOnly = ctx.dir("src/readonly")
            ctx.file("src/readonly/inner.txt")
            try ctx.setModificationDate(readOnly, Date(timeIntervalSince1970: 1_100_000_000))
            try ctx.setMode(readOnly, 0o555)
            let locked = ctx.file("src/locked.txt")
            try ctx.setFlags(locked, UInt32(UF_IMMUTABLE))
            let dst = ctx.dir("dst")
            let out = await ctx.perform(.copy(sources: [doc, readOnly, locked], destination: dst))
            try ctx.expect(out.skipped.isEmpty, "nothing skipped: \(out.skipped)")
            let copiedDoc = ctx.path("dst/doc.txt")
            try ctx.expectEqual(ctx.xattr(copiedDoc, "com.macexplorer.test"), "v1", "xattr preserved")
            try ctx.expectEqual(ctx.mode(copiedDoc), 0o640, "file mode preserved")
            try ctx.expectEqual(ctx.mtimeSeconds(copiedDoc), 1_000_000_000, "file mtime preserved")
            let copiedDir = ctx.path("dst/readonly")
            try ctx.expect(ctx.exists(ctx.path("dst/readonly/inner.txt")), "child copied into a read-only folder")
            try ctx.expectEqual(ctx.mode(copiedDir), 0o555, "directory mode applied post-order")
            try ctx.expectEqual(ctx.mtimeSeconds(copiedDir), 1_100_000_000, "directory mtime applied after its children")
            try ctx.expect(ctx.flags(ctx.path("dst/locked.txt")) & UInt32(UF_IMMUTABLE) != 0, "uchg preserved")
        },
        CoreScenario("ops.duplicateNaming") { ctx in
            let a = ctx.file("a.txt")
            let d = ctx.dir("d")
            ctx.file("d/x.txt")
            _ = await ctx.perform(.duplicate([a]))
            _ = await ctx.perform(.duplicate([a]))
            _ = await ctx.perform(.duplicate([d]))
            try ctx.expectEqual(ctx.entries(ctx.work), ["a.txt", "a copy.txt", "a copy 2.txt", "d", "d copy"], "Finder-style names")
            try ctx.expect(ctx.exists(ctx.path("d copy/x.txt")), "folder duplicated recursively")
        },
        CoreScenario("ops.copyIntoSameFolderMakesCopy") { ctx in
            let a = ctx.file("a.txt")
            _ = await ctx.perform(.copy(sources: [a], destination: ctx.work))
            try ctx.expectEqual(ctx.entries(ctx.work), ["a.txt", "a copy.txt"], "copy-paste into the same folder")
        },
        CoreScenario("ops.moveSameVolumeKeepsIdentity") { ctx in
            let a = ctx.file("src/a.txt")
            ctx.file("src/d/b.txt")
            let inode = try ctx.unwrap(ctx.inode(a), "inode of a.txt")
            let dst = ctx.dir("dst")
            let source = try await ctx.open(ctx.path("src"))
            let out = await ctx.perform(.move(sources: [a, ctx.path("src/d")], destination: dst))
            try ctx.expect(out.skipped.isEmpty, "nothing skipped: \(out.skipped)")
            try ctx.expectEqual(ctx.inode(ctx.path("dst/a.txt")), inode, "same-volume move is a rename")
            try ctx.expect(!ctx.exists(a) && ctx.exists(ctx.path("dst/d/b.txt")), "moved")
            try await ctx.waitUntil("source model drops moved rows") { source.rowCount == 0 }
        },
        CoreScenario("ops.trashIntoSandboxTrash") { ctx in
            let a = ctx.file("a.txt")
            ctx.file("b.txt")
            let m = try await ctx.open(ctx.work)
            let out = await ctx.perform(.trash([a]))
            guard case .trashed(let original, let trashURL, _)? = out.record.actions.first else {
                throw ScenarioFailure("expected a .trashed action, got \(out.record.actions)")
            }
            try ctx.expectEqual(original.lastPathComponent, "a.txt", "original path recorded")
            try ctx.expect(ctx.exists(trashURL) && ctx.sandbox.contains(trashURL), "item is in the sandbox trash")
            try ctx.expect(!ctx.exists(a), "item left the folder")
            try await ctx.waitUntil("row removed") { ctx.names(m) == ["b.txt"] }
        },
        CoreScenario("ops.deletePermanently") { ctx in
            let d = ctx.dir("d")
            for i in 0..<50 { ctx.file("d/f\(i).txt") }
            let out = await ctx.perform(.delete([d]))
            try ctx.expect(!ctx.exists(d), "tree removed")
            try ctx.expect(!out.record.isUndoable, "permanent delete is not undoable")
        },
        CoreScenario("ops.newItems") { ctx in
            let first = await ctx.perform(.newItem(.folder, in: ctx.work))
            _ = await ctx.perform(.newItem(.folder, in: ctx.work))
            _ = await ctx.perform(.newItem(.textFile, in: ctx.work))
            _ = await ctx.perform(.newItem(.emptyFile, in: ctx.work))
            try ctx.expectEqual(ctx.entries(ctx.work), ["New Folder", "New Folder 2", "Untitled.txt", "Untitled"], "default names")
            try ctx.expect(first.localChanges.contains { $0.beginRename == "New Folder" }, "a new folder enters inline rename")
        },
        CoreScenario("ops.renameIncludingCaseOnly") { ctx in
            let a = ctx.file("a.txt")
            let m = try await ctx.open(ctx.work)
            _ = await ctx.perform(.rename(a, to: "b.txt"))
            try ctx.expectEqual(ctx.entries(ctx.work), ["b.txt"], "renamed")
            _ = await ctx.perform(.rename(ctx.path("b.txt"), to: "B.txt"))
            try ctx.expectEqual(ctx.entries(ctx.work), ["B.txt"], "case-only rename stored on disk")
            try await ctx.waitUntil("model shows the new case") { ctx.names(m) == ["B.txt"] }
        },
        CoreScenario("ops.aliasAndRelativeSymlink") { ctx in
            let a = ctx.file("a.txt", "target")
            let sub = ctx.dir("sub")
            let alias = await ctx.perform(.alias(sources: [a], destination: ctx.work))
            let aliasURL = try ctx.unwrap(alias.created.first, "alias URL")
            try ctx.expect(ctx.isAliasFile(aliasURL), "a Finder alias file was created")
            try ctx.expectEqual(ctx.resolveAlias(aliasURL)?.lastPathComponent, "a.txt", "alias resolves to the original")
            let link = await ctx.perform(.symlink(sources: [a], destination: sub))
            let linkURL = try ctx.unwrap(link.created.first, "symlink URL")
            let target = try ctx.unwrap(ctx.readLink(linkURL), "readlink")
            try ctx.expect(!target.hasPrefix("/"), "same-volume symlink is relative, got \(target)")
            try ctx.expectEqual(ctx.size(linkURL.deletingLastPathComponent().appending(path: target)), 6, "symlink resolves to a.txt")
        },
        CoreScenario("ops.chmodRecursive") { ctx in
            let d = ctx.dir("d")
            let f = ctx.file("d/f.txt")
            let s = ctx.dir("d/s")
            let g = ctx.file("d/s/g.txt")
            _ = await ctx.perform(.chmodRecursive(d, ModeChange(mode: 0o700)))
            for url in [d, f, s, g] { try ctx.expectEqual(ctx.mode(url), 0o700, "mode of \(url.lastPathComponent)") }
        },
        CoreScenario("ops.setAttributesLockedHidden") { ctx in
            let a = ctx.file("a.txt")
            _ = await ctx.perform(.setAttributes([a], .locked(true)))
            try ctx.expect(ctx.flags(a) & UInt32(UF_IMMUTABLE) != 0, "locked")
            _ = await ctx.perform(.setAttributes([a], .locked(false)))
            try ctx.expect(ctx.flags(a) & UInt32(UF_IMMUTABLE) == 0, "unlocked")
            _ = await ctx.perform(.setAttributes([a], .hidden(true)))
            try ctx.expect(ctx.flags(a) & UInt32(UF_HIDDEN) != 0, "UF_HIDDEN set")
        },
        CoreScenario("ops.refusesCopyOrMoveIntoItself") { ctx in
            let folder = ctx.dir("A")
            let sub = ctx.dir("A/sub")
            let other = ctx.file("other.txt")
            let copy = await ctx.perform(.copy(sources: [folder, other], destination: sub))
            try ctx.expect(copy.skipped.contains { $0.url.lastPathComponent == "A" && $0.reason == .intoItself },
                           "copy into its own descendant refused: \(copy.skipped)")
            try ctx.expect(ctx.exists(ctx.path("A/sub/other.txt")), "other items in the same paste proceed")
            try ctx.expect(!ctx.exists(ctx.path("A/sub/A")), "nothing copied recursively")
            let move = await ctx.perform(.move(sources: [folder], destination: folder))
            try ctx.expect(move.skipped.contains { $0.reason == .intoItself }, "move onto itself refused: \(move.skipped)")
            try ctx.expect(ctx.exists(folder), "folder intact")
        },
        CoreScenario("ops.missingSourceSkipped") { ctx in
            let a = ctx.file("a.txt")
            let dst = ctx.dir("dst")
            let out = await ctx.perform(.copy(sources: [a, ctx.path("missing.txt")], destination: dst))
            try ctx.expect(ctx.exists(ctx.path("dst/a.txt")), "existing item copied")
            try ctx.expect(out.skipped.contains { $0.url.lastPathComponent == "missing.txt" && $0.reason == .sourceGone },
                           "missing item reported per item: \(out.skipped)")
        },
    ]
}
