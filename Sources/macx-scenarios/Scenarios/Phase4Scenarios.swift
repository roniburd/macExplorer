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
        CoreScenario("archive.linkChainRefused") { ctx in
            ctx.file("outside/keep.txt", "keep")
            ctx.writeData("inbox/chain.tar", ScenarioArchives.linkChainTar())
            ctx.setInteraction(ScriptedInteraction(errors: [.skip]))
            let o = await ctx.perform(.extract(ctx.path("inbox/chain.tar")))
            try ctx.expect(o.created.isEmpty, "nothing extracted: \(o.created)")
            try ctx.expectEqual(ctx.entries(ctx.path("inbox")), ["chain.tar"], "no result or partial folder left")
            try ctx.expectEqual(ctx.text(ctx.path("outside/keep.txt")), "keep", "sibling unchanged")
            try ctx.expectEqual(ctx.entries(ctx.path("outside")), ["keep.txt"], "sibling unchanged")
        },
        // QA round 2: a zip's local entries missing from its central directory are never written (bsdtar extracts
        // exactly what it listed and checked).
        CoreScenario("archive.zipHiddenLocalEntriesNotWritten") { ctx in
            ctx.file("outside/keep.txt", "keep")
            ctx.writeData("inbox/hiddenlocal.zip", ScenarioArchives.hiddenLocalZip(absolute: ctx.path("outside").path + "/ABS-ESCAPE.txt"))
            let o = await ctx.perform(.extract(ctx.path("inbox/hiddenlocal.zip")))
            try ctx.expectEqual(o.created.map(\.lastPathComponent), ["safe.txt"], "only the listed entry")
            try ctx.expectEqual(ctx.entries(ctx.path("inbox")).sorted(), ["hiddenlocal.zip", "safe.txt"], "nothing hidden written")
            try ctx.expectEqual(ctx.entries(ctx.path("outside")), ["keep.txt"], "sibling unchanged")
        },
        // QA round 2: a single symlink is zipped as the link, under its own name (as .aar always did).
        CoreScenario("archive.compressSymlinkStoresTheLink") { ctx in
            ctx.file("a.txt", "A")
            let link = ctx.path("link-to-a").path
            try await ctx.onLane { guard symlink("a.txt", link) == 0 else { throw ScenarioFailure("symlink: \(errno)") } }
            for format in [ArchiveFormat.zip, .appleArchive] {
                let o = await ctx.perform(.compress([ctx.path("link-to-a")], format))
                let name = "link-to-a." + (format == .zip ? "zip" : "aar")
                try ctx.expectEqual(o.created.map(\.lastPathComponent), [name], "named after the link")
                ctx.dir("out-\(name)")
                try ctx.renameRaw(ctx.path(name), to: ctx.path("out-\(name)/\(name)"))
                let extracted = await ctx.perform(.extract(ctx.path("out-\(name)/\(name)")))
                try ctx.expectEqual(extracted.created.map(\.lastPathComponent), ["link-to-a"], "the link comes back: \(name)")
                let back = ctx.path("out-\(name)/link-to-a").path
                let text = try await ctx.onLane { try FileManager.default.destinationOfSymbolicLink(atPath: back) }
                try ctx.expectEqual(text, "a.txt", "still a link to a.txt: \(name)")
            }
        },
        CoreScenario("batch.renameSameNameInTwoFolders") { ctx in
            ctx.file("p/x.txt", "P"); ctx.file("q/x.txt", "Q")
            var rules = BatchRenameRules()
            rules.prefix = "new "
            let preview = BatchRenamePlanner.preview([ctx.path("p/x.txt"), ctx.path("q/x.txt")], rules: rules,
                                                     caseSensitive: false, existingNames: [])
            try ctx.expect(preview.canApply, "search results in two folders can take the same new name: \(preview.rows.map(\.status))")
            _ = await ctx.perform(.batchRename(BatchRenamePlanner.pairs(preview)))
            try ctx.expect(ctx.text(ctx.path("p/new x.txt")) == "P" && ctx.text(ctx.path("q/new x.txt")) == "Q", "each renamed in its folder")
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
        CoreScenario("keymap.resetFollowsThePreset") { ctx in
            let settings = Settings(storage: InMemorySettingsStorage(), home: ctx.work)
            settings.applyKeymapPreset(.finder)
            try ctx.expect(!Command.allCases.contains { settings.isShortcutModified($0) }, "nothing modified right after Finder")
            settings.keyBindingOverrides.setPrimary(KeyChord(parsing: "cmd+9"), for: .viewAsIcons)
            settings.resetShortcut(.viewAsIcons)
            try ctx.expectEqual(settings.keyBindings.primary(.viewAsIcons), KeyChord(parsing: "cmd+1"), "Finder's ⌘1 back")
            try ctx.expectEqual(settings.keyBindings.primary(.viewAsDetails), KeyChord(parsing: "cmd+2"), "Details keeps ⌘2")
            try ctx.expectEqual(settings.keymapPreset, .finder, "still the Finder preset")
        },
        // QA round 2: Finder-like edits on the Explorer base read back as Explorer-based after a relaunch.
        CoreScenario("keymap.explorerBaseSurvivesRelaunch") { ctx in
            let storage = InMemorySettingsStorage()
            let a = Settings(storage: storage, home: ctx.work)
            let finder = KeyBindings(overrides: KeymapPreset.finder.overrides)
            for command: Command in [.cut, .copy, .paste, .selectAll, .undo, .redo, .moveToTrash, .deletePermanently,
                                     .properties, .back, .forward, .up] {
                for alternate in a.keyBindings.alternates(command) where !finder.alternates(command).contains(alternate) {
                    a.keyBindingOverrides.removeAlternate(alternate, from: command)
                }
            }
            let b = Settings(storage: storage, home: ctx.work)
            try ctx.expectEqual(b.keymapBase, .explorer, "base after relaunch")
            try ctx.expect(b.isShortcutModified(.copy) && !b.isShortcutModified(.rename), "modified relative to Explorer")
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

/// Crafted tars and zips (a copy of the writers in the CoreTests' CraftedArchives: the scenario target can't import test code).
enum ScenarioArchives {
    /// One entry, `../escape.txt`.
    static func traversalTar() -> Data { tar([(path: "../escape.txt", type: 0x30, link: "", contents: Data("escaped".utf8))]) }

    /// QA round 1: "d/l1 -> .." and links through it that resolve outside the extracted folder.
    static func linkChainTar() -> Data {
        tar([(path: "d/", type: 0x35, link: "", contents: Data()), (path: "d/l1", type: 0x32, link: "..", contents: Data()),
             (path: "l2", type: 0x32, link: "d/l1/..", contents: Data()),
             (path: "l3", type: 0x32, link: "d/l1/../../outside/keep.txt", contents: Data())])
    }

    /// QA round 2: local entries "hidden-not-in-cd.txt" and `absolute` that the central directory omits, then
    /// "safe.txt", which it lists (a stored zip; a copy of CoreTests' CraftedArchives.zip).
    static func hiddenLocalZip(absolute: String) -> Data {
        var out = Data(), central = Data()
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
        func crc32(_ data: Data) -> UInt32 {
            var crc: UInt32 = 0xFFFF_FFFF
            for byte in data {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
            }
            return ~crc
        }
        let entries: [(String, Data, Bool)] = [("hidden-not-in-cd.txt", Data("hidden".utf8), false),
                                               (absolute, Data("abs".utf8), false), ("safe.txt", Data("safe".utf8), true)]
        for (path, contents, listed) in entries {
            let name = Array(path.utf8), crc = crc32(contents), size = UInt32(contents.count), offset = UInt32(out.count)
            out.append(contentsOf: [0x50, 0x4B, 0x03, 0x04] + le16(10) + le16(0) + le16(0) + le16(0) + le16(0) + le32(crc)
                       + le32(size) + le32(size) + le16(name.count) + le16(0) + name)
            out.append(contents)
            guard listed else { continue }
            central.append(contentsOf: [0x50, 0x4B, 0x01, 0x02] + le16(0x031E) + le16(10) + le16(0) + le16(0) + le16(0) + le16(0)
                           + le32(crc) + le32(size) + le32(size) + le16(name.count) + le16(0) + le16(0) + le16(0) + le16(0)
                           + le32(UInt32(0o100644) << 16) + le32(offset) + name)
        }
        let cdOffset = UInt32(out.count)
        out.append(central)
        out.append(contentsOf: [0x50, 0x4B, 0x05, 0x06] + le16(0) + le16(0) + le16(1) + le16(1)
                   + le32(UInt32(central.count)) + le32(cdOffset) + le16(0))
        return out
    }

    /// A ustar archive of `entries` (type '0' file, '2' symlink, '5' folder).
    static func tar(_ entries: [(path: String, type: UInt8, link: String, contents: Data)]) -> Data {
        var out = Data()
        for e in entries {
            var h = [UInt8](repeating: 0, count: 512)
            func put(_ s: String, _ offset: Int, _ len: Int) { for (i, b) in s.utf8.prefix(len).enumerated() { h[offset + i] = b } }
            func octal(_ v: Int, _ offset: Int, _ len: Int) {
                let digits = String(v, radix: 8)
                put(String(repeating: "0", count: max(0, len - 1 - digits.count)) + digits, offset, len - 1)
            }
            put(e.path, 0, 100); octal(e.type == 0x35 ? 0o755 : 0o644, 100, 8); octal(0, 108, 8); octal(0, 116, 8)
            octal(e.contents.count, 124, 12); octal(1_700_000_000, 136, 12)
            for i in 148..<156 { h[i] = 0x20 }
            h[156] = e.type; put(e.link, 157, 100); put("ustar", 257, 6); put("00", 263, 2)
            let digits = String(h.reduce(0) { $0 + Int($1) }, radix: 8)
            put(String(repeating: "0", count: max(0, 6 - digits.count)) + digits + "\0 ", 148, 8)
            out.append(contentsOf: h)
            out.append(e.contents)
            out.append(Data(count: (512 - e.contents.count % 512) % 512))
        }
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
