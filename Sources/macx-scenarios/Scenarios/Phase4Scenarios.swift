import Core
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Phase 4 core scenarios (P4-23, reduced scope: no tags, helper, network or dual pane). Every file is created in the
/// scenario's own sandbox; the unsafe-archive scenario also checks that a sibling folder outside the target is
/// unchanged.
enum Phase4Scenarios {
    static let all: [CoreScenario] = [
        CoreScenario("archive.compressExtractRoundTrip") { ctx in
            ctx.file("photos/a.jpg", "A"); ctx.file("photos/sub/b.jpg", "B")
            let zip = await ctx.perform(.compress([ctx.path("photos")], .zip))
            try ctx.expectEqual(zip.created.map(\.lastPathComponent), ["photos.zip"], "archive next to the folder")
            ctx.dir("out")
            try ctx.renameRaw(ctx.path("photos.zip"), to: ctx.path("out/photos.zip"))
            let o = await ctx.perform(.extract(ctx.path("out/photos.zip")))
            try ctx.expectEqual(o.created.map(\.lastPathComponent), ["photos"], "extracted folder")
            try ctx.expectEqual(ctx.text(ctx.path("out/photos/sub/b.jpg")), "B", "contents")
            try ctx.expect(!ctx.entries(ctx.path("out")).contains { $0.hasPrefix(".macx-") }, "no staging left")
        },
        CoreScenario("archive.appleArchiveNextFreeName") { ctx in
            ctx.file("docs/a.txt", "A")
            _ = await ctx.perform(.compress([ctx.path("docs")], .appleArchive))
            let second = await ctx.perform(.compress([ctx.path("docs")], .appleArchive))
            try ctx.expectEqual(second.created.map(\.lastPathComponent), ["docs 2.aar"], "the taken name is never overwritten")
            let back = await ctx.perform(.extract(ctx.path("docs.aar")))
            try ctx.expectEqual(back.created.map(\.lastPathComponent), ["docs 2"], "existing folder docs → docs 2")
            try ctx.expectEqual(ctx.text(ctx.path("docs 2/a.txt")), "A", "contents")
        },
        CoreScenario("archive.unsafeRefused") { ctx in
            ctx.file("outside/keep.txt", "keep")
            ctx.writeData("inbox/evil.tar", ScenarioArchives.traversalTar())
            ctx.setInteraction(ScriptedInteraction(errors: [.skip]))
            let o = await ctx.perform(.extract(ctx.path("inbox/evil.tar")))
            try ctx.expect(o.created.isEmpty, "nothing extracted: \(o.created)")
            try ctx.expectEqual(ctx.entries(ctx.path("inbox")), ["evil.tar"], "no partial folder left")
            try ctx.expect(!ctx.exists(ctx.path("escape.txt")) && !ctx.exists(ctx.work.deletingLastPathComponent().appending(path: "escape.txt")),
                           "nothing escaped the target")
            try ctx.expectEqual(ctx.text(ctx.path("outside/keep.txt")), "keep", "sibling unchanged")
            try ctx.expectEqual(ctx.entries(ctx.path("outside")), ["keep.txt"], "sibling unchanged")
        },
        CoreScenario("batch.renameCycleAndUndo") { ctx in
            ctx.file("y/x.txt", "X"); ctx.file("y/y.txt", "Y"); ctx.file("y/z.txt", "Z")
            let pairs = [("x.txt", "y.txt"), ("y.txt", "z.txt"), ("z.txt", "x.txt")].map {
                BatchRenamePair(url: ctx.path("y/\($0.0)"), newName: $0.1)
            }
            let o = await ctx.perform(.batchRename(pairs))
            try ctx.expectEqual(o.record.actions.count, 3, "three renames, one job")
            try ctx.expect(ctx.text(ctx.path("y/y.txt")) == "X" && ctx.text(ctx.path("y/z.txt")) == "Y"
                           && ctx.text(ctx.path("y/x.txt")) == "Z", "cycle")
            try ctx.expectEqual(ctx.entries(ctx.path("y")), ["x.txt", "y.txt", "z.txt"], "no temporaries left")
            _ = try await ctx.undo()
            try ctx.expect(ctx.text(ctx.path("y/x.txt")) == "X" && ctx.text(ctx.path("y/y.txt")) == "Y"
                           && ctx.text(ctx.path("y/z.txt")) == "Z", "one undo restores every name")
        },
        CoreScenario("batch.renameSwapAndChain") { ctx in
            ctx.file("s/a.txt", "A"); ctx.file("s/b.txt", "B")
            _ = await ctx.perform(.batchRename([BatchRenamePair(url: ctx.path("s/a.txt"), newName: "b.txt"),
                                                BatchRenamePair(url: ctx.path("s/b.txt"), newName: "a.txt")]))
            try ctx.expect(ctx.text(ctx.path("s/a.txt")) == "B" && ctx.text(ctx.path("s/b.txt")) == "A", "swap")
            ctx.file("c/1.txt", "1"); ctx.file("c/2.txt", "2"); ctx.file("c/3.txt", "3")
            _ = await ctx.perform(.batchRename([("1.txt", "2.txt"), ("2.txt", "3.txt"), ("3.txt", "4.txt")].map {
                BatchRenamePair(url: ctx.path("c/\($0.0)"), newName: $0.1)
            }))
            try ctx.expectEqual(ctx.entries(ctx.path("c")), ["2.txt", "3.txt", "4.txt"], "chain")
            try ctx.expectEqual(ctx.text(ctx.path("c/4.txt")), "3", "chain contents")
        },
        CoreScenario("batch.renameCrashRecovery", requires: .helperProcess, timeout: .seconds(120)) { ctx in
            ctx.file("r/a.txt", "A"); ctx.file("r/b.txt", "B")
            try await ctx.crashBatchRename(in: "r", ["a.txt": "b.txt", "b.txt": "a.txt"])
            try ctx.expect(ctx.entries(ctx.path("r")).allSatisfy { $0.hasPrefix(".macx-br-") }, "killed with every item staged")
            let report = await ctx.runLaunchRecovery()
            try ctx.expect(ctx.text(ctx.path("r/a.txt")) == "A" && ctx.text(ctx.path("r/b.txt")) == "B", "originals back")
            try ctx.expectEqual(ctx.entries(ctx.path("r")), ["a.txt", "b.txt"], "no temporaries left")
            try ctx.expectEqual(report.restoredRenames.count, 2, "reported")
        },
        CoreScenario("acl.editUndo") { ctx in
            let a = ctx.file("a.txt")
            let e = ACLEntry(kind: .allow, principal: PrincipalDirectory.everyone, permissions: .readOnlyPreset)
            _ = await ctx.perform(.setAttributes([a], .acl([e])))
            let written = try await ctx.onLane { try ACLIO.read(a) }
            try ctx.expectEqual(written, [e], "written")
            _ = try await ctx.undo()
            let undone = try await ctx.onLane { try ACLIO.read(a) }
            try ctx.expectEqual(undone, [], "undone")
        },
        CoreScenario("icon.setCustomIconUndo") { ctx in
            let a = ctx.file("a.txt")
            let writer = WorkspaceIconWriter()
            _ = await ctx.perform(.setCustomIcon([a], IconImageData(bytes: ScenarioImages.png())))
            let set = try await ctx.onLane { try writer.currentCustomIcon(a) }
            try ctx.expect(set != nil, "custom icon set")
            _ = try await ctx.undo()
            let undone = try await ctx.onLane { try writer.currentCustomIcon(a) }
            try ctx.expect(undone == nil, "undo removed it")
            try ctx.expectEqual(ctx.text(a), "x", "the file's data is untouched")
        },
        CoreScenario("keymap.importRejectsConflicts") { _ in
            let bad = Data(#"{"format":"macexplorer-keymap","version":1,"base":"explorer","bindings":{"newFolder":{"primary":"cmd+l"}}}"#.utf8)
            let accepted: Bool
            do throws(KeymapImportError) {
                _ = try KeymapDocument.import(bad)
                accepted = true
            } catch {
                guard case .issues(let issues) = error, !issues.isEmpty else { throw ScenarioFailure("wrong error: \(error)") }
                accepted = false
            }
            if accepted { throw ScenarioFailure("accepted a keymap with newFolder on cmd+l (Go to address)") }
        },
        CoreScenario("keymap.exportImportRoundTrip") { ctx in
            let doc = Data(#"{"format":"macexplorer-keymap","version":1,"base":"finder","bindings":{"newFolder":{"primary":"cmd+opt+n"},"futureCommand":{"primary":"cmd+9"}}}"#.utf8)
            let (overrides, warnings) = try KeymapDocument.import(doc)
            try ctx.expectEqual(warnings, [.unknownCommand("futureCommand")], "a newer version's command is skipped with a warning")
            let file = ctx.writeData("exported.keymap.json", KeymapDocument.export(overrides))
            let read = try await ctx.onLane { try Data(contentsOf: file) }
            let (back, again) = try KeymapDocument.import(read)
            try ctx.expectEqual(again, [], "no warnings")
            try ctx.expectEqual(KeyBindings(overrides: back).primary(.newFolder), KeyChord(parsing: "cmd+opt+n"), "binding kept")
            try ctx.expect(KeyBindings(overrides: back).sameTriggers(as: KeyBindings(overrides: overrides)), "everything else kept")
        },
    ]
}

/// A crafted tar whose only entry is `../escape.txt` (a copy of the tar writer in the CoreTests' CraftedArchives: the
/// scenario target can't import test code).
enum ScenarioArchives {
    static func traversalTar() -> Data { tar(path: "../escape.txt", contents: Data("escaped".utf8)) }

    static func tar(path: String, contents: Data) -> Data {
        var h = [UInt8](repeating: 0, count: 512)
        func put(_ s: String, _ offset: Int, _ len: Int) { for (i, b) in s.utf8.prefix(len).enumerated() { h[offset + i] = b } }
        func octal(_ v: Int, _ offset: Int, _ len: Int) {
            let digits = String(v, radix: 8)
            put(String(repeating: "0", count: max(0, len - 1 - digits.count)) + digits, offset, len - 1)
        }
        put(path, 0, 100); octal(0o644, 100, 8); octal(0, 108, 8); octal(0, 116, 8)
        octal(contents.count, 124, 12); octal(1_700_000_000, 136, 12)
        for i in 148..<156 { h[i] = 0x20 }
        h[156] = 0x30; put("ustar", 257, 6); put("00", 263, 2)
        let sum = h.reduce(0) { $0 + Int($1) }
        let digits = String(sum, radix: 8)
        put(String(repeating: "0", count: max(0, 6 - digits.count)) + digits + "\0 ", 148, 8)
        var out = Data(h)
        out.append(contents)
        out.append(Data(count: (512 - contents.count % 512) % 512))
        out.append(Data(count: 1024))
        return out
    }
}

/// A solid-colour PNG built in memory (custom icon scenario).
enum ScenarioImages {
    static func png(size: Int = 64) -> Data {
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              case let out = NSMutableData(),
              let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return Data() }
        ctx.setFillColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        guard let image = ctx.makeImage() else { return Data() }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
}
