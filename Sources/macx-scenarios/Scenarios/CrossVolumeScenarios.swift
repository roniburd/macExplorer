import Core
import Darwin
import Foundation

enum CrossVolumeScenarios {
    @MainActor static func noPartials(_ ctx: ScenarioContext, _ dir: URL) -> Bool {
        ctx.entries(dir).allSatisfy { !$0.contains(".macx-partial-") }
    }

    static func bytesDone(_ queue: FileOpQueue, _ id: JobID) async -> Int64? {
        await queue.snapshots().first { $0.id == id }?.progress.bytesDone
    }

    static let all: [CoreScenario] = [
        CoreScenario("xvol.moveTreeToAPFSImage", requires: .diskImages) { ctx in
            let image = try await ctx.image("move", .apfs, sizeMB: 64)
            ctx.file("src/a.txt", "aaaa")
            ctx.file("src/d/b.txt", "bb")
            ctx.dir("src/d/empty")
            try ctx.symlink("src/d/link", to: "b.txt")
            let out = await ctx.perform(.move(sources: [ctx.path("src/a.txt"), ctx.path("src/d")], destination: image.mountPoint))
            try ctx.expect(out.skipped.isEmpty, "nothing skipped: \(out.skipped)")
            try ctx.expect(!ctx.exists(ctx.path("src/a.txt")) && !ctx.exists(ctx.path("src/d")), "sources deleted after the verified copy")
            try ctx.expectEqual(ctx.size(image.mountPoint.appending(path: "a.txt")), 4, "a.txt landed")
            try ctx.expectEqual(ctx.readLink(image.mountPoint.appending(path: "d/link")), "b.txt", "symlink moved as a link")
            try ctx.expect(ctx.isDirectory(image.mountPoint.appending(path: "d/empty")), "empty folder moved")
            try ctx.expect(noPartials(ctx, image.mountPoint), "no partials left")
            let journal = await ctx.env.journal.entries()
            try ctx.expect(journal.isEmpty, "journal cleared after success: \(journal)")
        },
        CoreScenario("xvol.replaceAcrossVolumes", requires: .diskImages) { ctx in
            let image = try await ctx.image("replace", .apfs, sizeMB: 64)
            let src = ctx.file("a.txt", "hello")
            let dest = ctx.file(at: image.mountPoint.appending(path: "a.txt"), "x")
            let trash = ctx.dir(at: image.mountPoint.appending(path: ".macx-trash"))
            let queue = ctx.makeQueue(trash: trash, interaction: ScriptedInteraction(conflicts: [.one(.replace)]))
            let out = await ctx.run(queue, .move(sources: [src], destination: image.mountPoint))
            try ctx.expectEqual(ctx.size(dest), 5, "replaced")
            try ctx.expect(!ctx.exists(src), "source removed after the verified replace")
            try ctx.expect(out.record.actions.contains { if case .replaced = $0 { true } else { false } }, "replacement recorded for undo")
            try ctx.expect(noPartials(ctx, image.mountPoint), "no partials left")
        },
        CoreScenario("xvol.pauseAndResumeMidCopy", requires: .diskImages, timeout: .seconds(120)) { ctx in
            let image = try await ctx.image("pause", .hfsPlus, sizeMB: 128)
            let big = ctx.file("big.bin", bytes: 64 << 20)
            let gate = ChunkGate()
            defer { gate.open() }
            let queue = ctx.makeQueue(trash: ctx.dir("t"), interaction: ScriptedInteraction(), tuning: gate.tuning)
            let id = await queue.enqueue(JobRequest(.copy(sources: [big], destination: image.mountPoint), registersUndo: false))
            try await ctx.waitUntil("copy held at its first chunk") { gate.isHeld }
            await queue.pause(id)
            gate.open()
            try await ctx.waitUntilAsync("paused") { await queue.snapshots().first { $0.id == id }?.state == .paused }
            // Bytes are counted before the chunk hook, and the pause checkpoint runs right after it: nothing moves now.
            let before = await bytesDone(queue, id)
            try ctx.expect((before ?? 0) > 0, "paused after the first chunk (\(String(describing: before)) bytes)")
            try await Task.sleep(for: .milliseconds(400))      // a negative check: it can only miss a late byte
            let after = await bytesDone(queue, id)
            try ctx.expectEqual(after, before, "no bytes copied while paused")
            await queue.resume(id)
            let out = await queue.outcome(of: id)
            try ctx.expect(!out.wasCancelled && out.skipped.isEmpty, "copy finished after resume")
            try ctx.expectEqual(ctx.size(image.mountPoint.appending(path: "big.bin")), Int64(64 << 20), "full size")
        },
        CoreScenario("xvol.cancelMidCopyAppliesFolderMetadata", requires: .diskImages, timeout: .seconds(120)) { ctx in
            let image = try await ctx.image("cancel", .hfsPlus, sizeMB: 128)
            let tree = ctx.dir("tree")
            ctx.file("tree/big.bin", bytes: 64 << 20)
            ctx.file("tree/z-after.txt")
            try ctx.setMode(tree, 0o755)
            let gate = ChunkGate()
            defer { gate.open() }
            let queue = ctx.makeQueue(trash: ctx.dir("t"), interaction: ScriptedInteraction(), tuning: gate.tuning)
            let id = await queue.enqueue(JobRequest(.copy(sources: [tree], destination: image.mountPoint), registersUndo: false))
            try await ctx.waitUntil("copy held at its first chunk") { gate.isHeld }
            await queue.cancel(id)
            gate.open()
            let out = await queue.outcome(of: id)
            try ctx.expect(out.wasCancelled, "cancelled")
            let copied = image.mountPoint.appending(path: "tree")
            if ctx.exists(copied) {
                try ctx.expectEqual(ctx.mode(copied), 0o755, "a cancelled copy never leaves a folder at 0700")
            }
            try ctx.expect(ctx.exists(tree.appending(path: "big.bin")), "source untouched")
        },
        CoreScenario("xvol.moveKeepsSourceThatChangedDuringCopy", requires: .diskImages) { ctx in
            let image = try await ctx.image("changed", .apfs, sizeMB: 64)
            let src = ctx.file("log.txt", bytes: 1 << 20)
            let path = src.path
            let tuning = FileOpTuning(faultHook: { point, _ in
                guard point == .afterPartialCopy else { return }
                let fd = open(path, O_WRONLY | O_APPEND)
                if fd >= 0 {
                    _ = write(fd, "more", 4)
                    close(fd)
                }
            })
            let queue = ctx.makeQueue(trash: ctx.dir(at: image.mountPoint.appending(path: ".macx-trash")),
                                      interaction: ScriptedInteraction(), tuning: tuning)
            let out = await ctx.run(queue, .move(sources: [src], destination: image.mountPoint))
            try ctx.expectEqual(ctx.size(src), Int64((1 << 20) + 4), "source NOT deleted and keeps the appended bytes")
            try ctx.expect(!ctx.exists(image.mountPoint.appending(path: "log.txt")), "no final copy")
            try ctx.expect(noPartials(ctx, image.mountPoint), "partial removed")
            try ctx.expect(out.skipped.contains { $0.reason == .changedDuringMove }, "reported as changed: \(out.skipped)")
        },
        CoreScenario("xvol.readOnlyDestinationReportsEROFS", requires: .diskImages) { ctx in
            let image = try await ctx.image("ro", .hfsPlus, sizeMB: 16, readOnly: true)
            let a = ctx.file("a.txt")
            let script = ScriptedInteraction(errors: [.cancel])
            ctx.setInteraction(script)
            _ = await ctx.perform(.copy(sources: [a], destination: image.mountPoint))
            try ctx.expectEqual(script.askedErrors().first?.kind, .readOnlyVolume, "EROFS mapped to readOnlyVolume")
            try ctx.expect(!ctx.exists(image.mountPoint.appending(path: "a.txt")), "nothing written")
        },
        CoreScenario("xvol.insufficientSpaceAsksFirst", requires: .diskImages) { ctx in
            let image = try await ctx.image("small", .hfsPlus, sizeMB: 16)
            let big = ctx.file("big.bin", bytes: 40 << 20)
            ctx.setInteraction(ScriptedInteraction(space: [false]))
            _ = await ctx.perform(.copy(sources: [big], destination: image.mountPoint))
            try ctx.expect(!ctx.exists(image.mountPoint.appending(path: "big.bin")), "declining the shortfall prompt copies nothing")
            try ctx.expectEqual(ctx.size(big), Int64(40 << 20), "source intact")
        },
        CoreScenario("xvol.exfatCaseOnlyRename", requires: .diskImages) { ctx in
            let image = try await ctx.image("exfat", .exfat, sizeMB: 32)
            let file = ctx.file(at: image.mountPoint.appending(path: "ab.txt"))
            let m = try await ctx.open(image.mountPoint)
            _ = await ctx.perform(.rename(file, to: "AB.txt"))
            let names = ctx.entries(image.mountPoint)
            try ctx.expect(names.contains("AB.txt") && !names.contains("ab.txt"), "case-only rename stored on exFAT: \(names)")
            try await ctx.waitUntil("model shows AB.txt") {
                ctx.names(m).contains("AB.txt") && !ctx.names(m).contains("ab.txt")
            }
        },
    ]
}
