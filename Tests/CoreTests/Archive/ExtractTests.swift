import XCTest
import Darwin
@testable import Core
import MacxFS
import MacxFixtures

/// P4-10: archive listing, the safety rules and the extract job. Every archive is crafted or created inside the
/// test's sandbox; the unsafe ones also check that a sibling folder outside the extraction target is unchanged.
final class ExtractTests: FileOpsTestCase {
    private func snapshot(_ dir: URL) -> [String: Data] {
        var out: [String: Data] = [:]
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil, options: [])!
        for case let u as URL in e { out[u.path] = (try? Data(contentsOf: u)) ?? Data("<dir>".utf8) }
        return out
    }

    func testSafetyRules() {
        func f(_ p: String) -> ArchiveEntry { ArchiveEntry(path: p, type: .file) }
        XCTAssertEqual(ArchiveSafety.problems([f("a/b.txt"), f("./c.txt")]), [])
        XCTAssertEqual(ArchiveSafety.problems([f("../escape.txt")]), [.parentTraversal("../escape.txt")])
        XCTAssertEqual(ArchiveSafety.problems([f("a/../../x")]), [.parentTraversal("a/../../x")])
        XCTAssertEqual(ArchiveSafety.problems([f("/abs.txt")]), [.absolutePath("/abs.txt")])
        XCTAssertEqual(ArchiveSafety.problems([ArchiveEntry(path: "link", type: .symlink(target: "../outside")), f("link/evil.txt")]),
                       [.parentTraversal("link"), .throughSymlink("link/evil.txt")])
        XCTAssertEqual(ArchiveSafety.problems([ArchiveEntry(path: "d/ok", type: .symlink(target: "../sibling.txt"))]), [])
        XCTAssertEqual(ArchiveSafety.problems([ArchiveEntry(path: "abs", type: .symlink(target: "/etc/hosts"))]), [.parentTraversal("abs")])
        var t = ArchiveSafety.Tracker()
        XCTAssertNil(t.check(ArchiveEntry(path: "l", type: .symlink(target: "x"))))
        XCTAssertEqual(t.check(f("l/y")), .throughSymlink("l/y"))
    }

    /// Beyond the plan's four rules: the root entry ("./", aa's ""), hard links, case-insensitive volumes and
    /// backslash separators (zips made on Windows).
    func testSafetyRulesForRootEntriesHardLinksCaseAndBackslashes() {
        func f(_ p: String) -> ArchiveEntry { ArchiveEntry(path: p, type: .file) }
        XCTAssertEqual(ArchiveSafety.problems([ArchiveEntry(path: "./", type: .directory), f("./a.txt")]), [])
        XCTAssertEqual(ArchiveSafety.problems([ArchiveEntry(path: ".", type: .directory)]), [])
        XCTAssertEqual(ArchiveSafety.problems([f("")]), [.unlistable])
        XCTAssertEqual(ArchiveSafety.problems([f("a\\b.txt")]), [])
        XCTAssertEqual(ArchiveSafety.problems([f("a\u{0}b")]), [.unlistable])
        XCTAssertEqual(ArchiveSafety.problems([ArchiveEntry(path: "h", type: .hardlink(target: "../outside/keep.txt"))]),
                       [.parentTraversal("h")])
        XCTAssertEqual(ArchiveSafety.problems([ArchiveEntry(path: "h", type: .hardlink(target: "/etc/hosts"))]), [.parentTraversal("h")])
        XCTAssertEqual(ArchiveSafety.problems([f("d/a.txt"), ArchiveEntry(path: "d/h", type: .hardlink(target: "d/a.txt"))]), [])
        XCTAssertEqual(ArchiveSafety.problems([ArchiveEntry(path: "l", type: .symlink(target: "x")),
                                               ArchiveEntry(path: "h", type: .hardlink(target: "l/y"))]), [.throughSymlink("h")])
        XCTAssertEqual(ArchiveSafety.problems([ArchiveEntry(path: "Link", type: .symlink(target: "x")), f("link/evil.txt")]),
                       [.throughSymlink("link/evil.txt")])
        XCTAssertEqual(ArchiveSafety.problems([f("..\\escape.txt")]), [.parentTraversal("..\\escape.txt")])
        XCTAssertEqual(ArchiveSafety.problems([f("./../x")]), [.parentTraversal("./../x")])
        XCTAssertEqual(ArchiveSafety.problems([f(".//abs.txt")]), [.absolutePath(".//abs.txt")])
    }

    /// QA round 1: a link target may not pass through another symlink entry ("d/l1 -> .." then "l2 -> d/l1/.."), in
    /// either order, since the lexical depth count assumes every component is a real folder.
    func testSafetyRulesRefuseTargetsThroughOtherLinks() {
        func l(_ p: String, _ t: String) -> ArchiveEntry { ArchiveEntry(path: p, type: .symlink(target: t)) }
        let d = ArchiveEntry(path: "d/", type: .directory)
        XCTAssertEqual(ArchiveSafety.problems([d, l("d/l1", ".."), l("l2", "d/l1/.."), l("l3", "d/l1/../../outside/keep.txt")]),
                       [.throughSymlink("l2"), .throughSymlink("l3")])
        XCTAssertEqual(ArchiveSafety.problems([d, l("l2", "d/l1/.."), l("d/l1", "..")]), [.throughSymlink("d/l1")])
        XCTAssertEqual(ArchiveSafety.problems([d, l("d/l1", ".."), l("l4", "d/l1")]), [], "a link to a link that stays inside is fine")
        XCTAssertEqual(ArchiveSafety.problems([d, l("d/x", "../y"), l("l5", "d/X/z")]), [.throughSymlink("l5")])
    }

    /// QA round 1: the d/l1 -> ".." chain in tar, zip and Apple Archive is refused, and nothing outside changes.
    func testExtractRefusesLinkChainEscape() async throws {
        try file("outside/keep.txt", "keep")
        let before = snapshot(url("outside"))
        try dir("src/chain/d")
        try sandbox.createSymlink("src/chain/d/l1", target: "..")
        try sandbox.createSymlink("src/chain/l2", target: "d/l1/..")
        try sandbox.createSymlink("src/chain/l3", target: "d/l1/../../outside/keep.txt")
        try dir("work"); try dir("made")
        _ = try ProcessRunnerTestTool.run("/usr/bin/aa", ["archive", "-d", url("src/chain").path, "-o", url("made/chain.aar").path])
        let archives: [(String, Data?)] = [
            ("chain.tar", CraftedArchives.tar([.init(path: "d/", type: 0x35), .init(path: "d/l1", type: 0x32, linkTarget: ".."),
                                               .init(path: "l2", type: 0x32, linkTarget: "d/l1/.."),
                                               .init(path: "l3", type: 0x32, linkTarget: "d/l1/../../outside/keep.txt")])),
            ("chain.zip", CraftedArchives.zip([.init(path: "d/"), .init(path: "d/l1", contents: Data("..".utf8), symlink: true),
                                               .init(path: "l2", contents: Data("d/l1/..".utf8), symlink: true),
                                               .init(path: "l3", contents: Data("d/l1/../../outside/keep.txt".utf8), symlink: true)])),
            ("chain.aar", nil),
        ]
        for (name, data) in archives {
            if let data { try sandbox.createFile("work/\(name)", contents: data) } else { try sandbox.rename("made/\(name)", to: "work/\(name)") }
            let interaction = ScriptedInteraction(errors: [.skip])
            let (queue, _) = makeQueue(interaction: interaction)
            let outcome = try await run(.extract(url("work/\(name)")), on: queue)
            XCTAssertEqual(interaction.askedErrors().map(\.kind), [.unsafeArchive], name)
            XCTAssertTrue(outcome.created.isEmpty, name)
            XCTAssertEqual(names(url("work")), [name], name)
            XCTAssertEqual(snapshot(url("outside")), before, name)
            try sandbox.remove("work/\(name)")
        }
    }

    func testListerParsesTarVerboseLines() {
        XCTAssertEqual(ArchiveLister.entry(path: "./l", verboseLine: "lrw-r--r--  0 0      0           0 Dec 31  1969 ./l -> a b -> c.txt"),
                       ArchiveEntry(path: "./l", type: .symlink(target: "a b -> c.txt")))
        XCTAssertEqual(ArchiveLister.entry(path: "h", verboseLine: "hrw-r--r--  0 0      0           0 Dec 31  1969 h link to ../x"),
                       ArchiveEntry(path: "h", type: .hardlink(target: "../x")))
        XCTAssertEqual(ArchiveLister.entry(path: "d/", verboseLine: "drwxr-xr-x  0 0      0           0 Dec 31  1969 d/"),
                       ArchiveEntry(path: "d/", type: .directory))
        XCTAssertEqual(ArchiveLister.entry(path: "a -> b", verboseLine: "-rw-r--r--  0 0      0           1 Dec 31  1969 a -> b"),
                       ArchiveEntry(path: "a -> b", type: .file))
        XCTAssertEqual(ArchiveLister.entry(path: "p", verboseLine: "prw-r--r--  0 0      0           0 Dec 31  1969 p"),
                       ArchiveEntry(path: "p", type: .other))
        XCTAssertNil(ArchiveLister.entry(path: "l", verboseLine: "lrw-r--r--  0 0      0           0 Dec 31  1969 other -> x"))
    }

    func testListerReadsEveryFormat() async throws {
        try file("src/n.txt", "N"); try file("src/sub/s.txt", "S"); try sandbox.createSymlink("src/ln", target: "n.txt")
        _ = try ProcessRunnerTestTool.run("/usr/bin/tar", ["-cf", url("t.tar").path, "-C", url("src").path, "."])
        _ = try ProcessRunnerTestTool.run("/usr/bin/aa", ["archive", "-d", url("src").path, "-o", url("s.aar").path])
        _ = try ProcessRunnerTestTool.run("/bin/sh", ["-c", "/usr/bin/gzip -c \"$0\" > \"$1\"", url("src/n.txt").path, url("n.txt.gz").path])
        try sandbox.createFile("link.zip", contents: CraftedArchives.zip([.init(path: "l", contents: Data("../x".utf8), symlink: true)]))
        let (tURL, aURL, gURL, zURL) = (url("t.tar"), url("s.aar"), url("n.txt.gz"), url("link.zip"))
        let (t, a, g, z) = try await LanePool().perform(on: .unknown, .fileOp) { lane in
            (try ArchiveLister.entries(of: tURL, format: .tar, context: lane),
             try ArchiveLister.entries(of: aURL, format: .appleArchive, context: lane),
             try ArchiveLister.entries(of: gURL, format: .gzip, context: lane),
             try ArchiveLister.entries(of: zURL, format: .zip, context: lane))
        }
        func sorted(_ e: [ArchiveEntry]) -> [ArchiveEntry] { e.sorted { $0.path < $1.path } }
        XCTAssertEqual(sorted(t), [ArchiveEntry(path: "./", type: .directory), ArchiveEntry(path: "./ln", type: .symlink(target: "n.txt")),
                                   ArchiveEntry(path: "./n.txt", type: .file), ArchiveEntry(path: "./sub/", type: .directory),
                                   ArchiveEntry(path: "./sub/s.txt", type: .file)])
        XCTAssertEqual(sorted(a), [ArchiveEntry(path: "ln", type: .symlink(target: "n.txt")), ArchiveEntry(path: "n.txt", type: .file),
                                   ArchiveEntry(path: "sub", type: .directory), ArchiveEntry(path: "sub/s.txt", type: .file)])
        XCTAssertEqual(g, [ArchiveEntry(path: "n.txt", type: .file)])
        XCTAssertEqual(z, [ArchiveEntry(path: "l", type: .symlink(target: "../x"))])
        let junk = try sandbox.createFile("junk.tar", contents: Data("not an archive at all".utf8))
        do {
            _ = try await LanePool().perform(on: .unknown, .fileOp) { lane in
                try ArchiveLister.entries(of: junk, format: .tar, context: lane)
            }
            XCTFail("expected unlistable")
        } catch { XCTAssertEqual(error as? ArchiveListError, .unlistable) }
    }
    func testExtractRefusesTraversalAbsoluteAndSymlinkEscape() async throws {
        try file("outside/keep.txt", "keep")
        let before = snapshot(url("outside"))
        let archives: [(String, Data)] = [
            ("trav.tar", CraftedArchives.tar([.init(path: "../escape.txt", contents: Data("x".utf8))])),
            ("abs.tar", CraftedArchives.tar([.init(path: "/abs.txt", contents: Data("x".utf8))])),
            ("link.tar", CraftedArchives.tar([.init(path: "link", type: 0x32, linkTarget: "../outside"),
                                              .init(path: "link/evil.txt", contents: Data("x".utf8))])),
            ("trav.zip", CraftedArchives.zip([.init(path: "../escape.txt", contents: Data("x".utf8))])),
            ("link.zip", CraftedArchives.zip([.init(path: "link", contents: Data("../outside".utf8), symlink: true),
                                              .init(path: "link/evil.txt", contents: Data("x".utf8))])),
        ]
        for (name, data) in archives {
            try sandbox.createFile("work/\(name)", contents: data)
            let interaction = ScriptedInteraction(errors: [.skip])
            let (queue, journal) = makeQueue(interaction: interaction)
            let outcome = try await run(.extract(url("work/\(name)")), on: queue)
            XCTAssertEqual(interaction.askedErrors().map(\.kind), [.unsafeArchive], name)
            XCTAssertTrue(outcome.created.isEmpty, name)
            XCTAssertEqual(names(url("work")), [name], name)                 // no partial dir, nothing extracted
            XCTAssertFalse(exists(url("escape.txt")), name); XCTAssertFalse(exists(url("abs.txt")), name)
            let left = await journal.entries()
            XCTAssertTrue(left.isEmpty, name)
            XCTAssertEqual(snapshot(url("outside")), before, name)
            try sandbox.remove("work/\(name)")
        }
    }
    func testExtractZipWithSingleTopLevelFolderAndNextFreeName() async throws {
        try file("photos/a.jpg", "A"); try file("photos/sub/b.jpg", "B")
        let (queue, _) = makeQueue()
        _ = try await run(.compress([url("photos")], .zip), on: queue)
        try dir("work"); try sandbox.rename("photos.zip", to: "work/photos.zip"); try dir("work/photos")
        let outcome = try await run(.extract(url("work/photos.zip")), on: queue)
        XCTAssertEqual(outcome.created.map(\.lastPathComponent), ["photos 2"])
        XCTAssertEqual(text(url("work/photos 2/sub/b.jpg")), "B")
        XCTAssertFalse(exists(url("work/photos 2/__MACOSX")))
        XCTAssertEqual(names(url("work")).filter { $0.hasPrefix(".macx-") }, [])
    }
    func testExtractNextFreeFolderName() async throws {
        let tar = CraftedArchives.tar([.init(path: "a.txt", contents: Data("1".utf8)), .init(path: "b.txt", contents: Data("2".utf8))])
        try sandbox.createFile("bundle.tar", contents: tar)
        try dir("bundle")
        let (queue, _) = makeQueue()
        let outcome = try await run(.extract(url("bundle.tar")), on: queue)
        XCTAssertEqual(outcome.created.map(\.lastPathComponent), ["bundle 2"])
        XCTAssertEqual(names(url("bundle 2")), ["a.txt", "b.txt"])
        XCTAssertEqual(names(url("bundle")), [])
    }
    func testExtractTarGzipGzipAndAppleArchive() async throws {
        try file("src/n.txt", "N")
        _ = try ProcessRunnerTestTool.run("/usr/bin/tar", ["-czf", url("t.tar.gz").path, "-C", url("src").path, "n.txt"])
        _ = try ProcessRunnerTestTool.run("/bin/sh", ["-c", "/usr/bin/gzip -c \"$0\" > \"$1\"", url("src/n.txt").path, url("one.txt.gz").path])
        _ = try ProcessRunnerTestTool.run("/usr/bin/aa", ["archive", "-d", url("src").path, "-o", url("s.aar").path])
        let (queue, _) = makeQueue()
        let a = try await run(.extract(url("t.tar.gz")), on: queue)
        let b = try await run(.extract(url("one.txt.gz")), on: queue)
        let c = try await run(.extract(url("s.aar")), on: queue)
        XCTAssertEqual(a.created.map(\.lastPathComponent), ["n.txt"])          // single top-level item lands as itself
        XCTAssertEqual(b.created.map(\.lastPathComponent), ["one.txt"])
        XCTAssertEqual(c.created.map(\.lastPathComponent), ["n 2.txt"])
        XCTAssertEqual(text(url("one.txt")), "N")
    }
    func testUnsupportedFormatIsReported() async throws {
        try sandbox.createFile("x.rar", contents: Data("Rar!\u{1A}\u{07}\u{00}".utf8))
        let interaction = ScriptedInteraction(errors: [.skip])
        let (queue, _) = makeQueue(interaction: interaction)
        _ = try await run(.extract(url("x.rar")), on: queue)
        XCTAssertEqual(interaction.askedErrors().map(\.kind), [.unsupportedArchive])
    }
    func testUndoTrashesExtractedItem() async throws {
        try sandbox.createFile("b.tar", contents: CraftedArchives.tar([.init(path: "only.txt", contents: Data("1".utf8))]))
        let (queue, _) = makeQueue()
        let outcome = try await run(.extract(url("b.tar")), on: queue)
        _ = try await run(.undo(outcome.record), on: queue)
        XCTAssertFalse(exists(url("only.txt")))
    }
    func testSetuidBitsAreCleared() async throws {
        var e = CraftedArchives.TarEntry(path: "tool", contents: Data("#!/bin/sh\n".utf8))
        e.type = 0x30
        var data = CraftedArchives.tar([e])
        let modeField = Array("0004755".utf8) + [0]                 // setuid + 755
        data.replaceSubrange(100..<108, with: modeField)
        let sum = data.prefix(512).enumerated().reduce(0) { $0 + (148..<156 ~= $1.offset ? 0x20 : Int($1.element)) }
        data.replaceSubrange(148..<156, with: Array((String(sum, radix: 8).leftPadded(6) + "\0 ").utf8))
        try sandbox.createFile("s.tar", contents: data)
        let (queue, _) = makeQueue()
        _ = try await run(.extract(url("s.tar")), on: queue)
        XCTAssertEqual(lst(url("tool")).st_mode & (S_ISUID | S_ISGID), 0)
    }

    func testExtractJobDescriptionVerbAndErrorResolutions() {
        let kind = JobKind.extract(url("a.zip"))
        XCTAssertEqual(kind.allURLs, [url("a.zip")])
        XCTAssertEqual(kind.verb, .extracting)
        XCTAssertEqual(kind.jobDescription, JobDescription(verb: .extracting, itemCount: 1, firstItemName: "a.zip",
                                                           sourceFolderName: root.lastPathComponent, destinationFolderName: nil))
        XCTAssertEqual(FileOpErrorKind.unsafeArchive.allowedResolutions, [.skip, .cancel])
        XCTAssertEqual(FileOpErrorKind.unsupportedArchive.allowedResolutions, [.skip, .cancel])
    }

    /// Several top-level items land in a folder named after the archive; a "__MACOSX" folder is dropped; a hard
    /// link inside the archive is kept.
    func testSeveralTopLevelItemsGoInAFolderAndMacOSXIsRemoved() async throws {
        let tar = CraftedArchives.tar([.init(path: "__MACOSX/._a.txt", contents: Data("rsrc".utf8)),
                                       .init(path: "a.txt", contents: Data("1".utf8)),
                                       .init(path: "h.txt", type: 0x31, linkTarget: "a.txt"),
                                       .init(path: "d", type: 0x35), .init(path: "d/ok", type: 0x32, linkTarget: "../a.txt")])
        try sandbox.createFile("x.tar", contents: tar)
        let (queue, journal) = makeQueue()
        let outcome = try await run(.extract(url("x.tar")), on: queue)
        XCTAssertEqual(outcome.created.map(\.lastPathComponent), ["x"])
        XCTAssertEqual(names(url("x")), ["a.txt", "d", "h.txt"])
        XCTAssertEqual(text(url("x/h.txt")), "1")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: url("x/d/ok").path), "../a.txt")
        XCTAssertEqual(lst(url("x")).st_mode & 0o777, 0o755, "the folder isn't left private like the partial")
        XCTAssertEqual(names(root).filter { $0.contains(".macx-") }, [])
        let left = await journal.entries()
        XCTAssertTrue(left.isEmpty)
        XCTAssertEqual(outcome.localChanges.first?.select, ["x"])
    }

    /// A hard link entry pointing outside is refused before anything is written.
    func testExtractRefusesHardLinkEscape() async throws {
        try file("outside/keep.txt", "keep")
        let before = snapshot(url("outside"))
        try sandbox.createFile("work/hard.tar", contents: CraftedArchives.tar([.init(path: "h", type: 0x31, linkTarget: "../outside/keep.txt")]))
        let interaction = ScriptedInteraction(errors: [.skip])
        let (queue, _) = makeQueue(interaction: interaction)
        let outcome = try await run(.extract(url("work/hard.tar")), on: queue)
        XCTAssertEqual(interaction.askedErrors().map(\.kind), [.unsafeArchive])
        XCTAssertEqual(interaction.askedErrors().first?.url, url("work/hard.tar"))
        XCTAssertEqual(outcome.skipped.map(\.url), [url("work/hard.tar")])
        XCTAssertEqual(names(url("work")), ["hard.tar"])
        XCTAssertEqual(snapshot(url("outside")), before)
    }

    /// A broken archive whose listing fails is unsafe too (rule 4), and Cancel cancels the job.
    func testUnlistableArchiveIsRefusedAndCancelCancels() async throws {
        try sandbox.createFile("bad.tar.gz", contents: Data([0x1F, 0x8B, 0x08, 0x00, 0x01, 0x02, 0x03]))
        let interaction = ScriptedInteraction(errors: [.cancel])
        let (queue, _) = makeQueue(interaction: interaction)
        let outcome = try await run(.extract(url("bad.tar.gz")), on: queue)
        XCTAssertEqual(interaction.askedErrors().map(\.kind), [.unsafeArchive])
        XCTAssertTrue(outcome.wasCancelled)
        XCTAssertEqual(names(root).filter { !$0.hasPrefix(".") && $0 != "state" }, ["bad.tar.gz"])
    }

    /// Cancel while the tool runs leaves no partial folder and an empty journal (Review Focus 4, extract half).
    func testCancelWhileExtractingLeavesNothing() async throws {
        var blob = Data(count: 64 << 20)
        blob.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
        try sandbox.createFile("src/blob", contents: blob)
        _ = try ProcessRunnerTestTool.run("/usr/bin/tar", ["-czf", url("big.tar.gz").path, "-C", url("src").path, "blob"])
        try dir("out"); try sandbox.rename("big.tar.gz", to: "out/big.tar.gz")
        let started = expectation(description: "tool started")
        let holder = QueueHolder()
        let tuning = FileOpTuning(faultHook: { point, id in
            if point == .archiveToolStarted { started.fulfill(); Task { await holder.queue?.cancel(id) } }
        })
        let (queue, journal) = makeQueue(tuning: tuning)
        holder.queue = queue
        let outcome = try await run(.extract(url("out/big.tar.gz")), on: queue)
        await fulfillment(of: [started], timeout: 10)
        XCTAssertTrue(outcome.wasCancelled)
        XCTAssertTrue(outcome.created.isEmpty)
        XCTAssertTrue(outcome.record.actions.isEmpty)
        XCTAssertEqual(names(url("out")), ["big.tar.gz"])
        let left = await journal.entries()
        XCTAssertTrue(left.isEmpty)
    }

    /// A failing tool is asked about (Retry/Skip/Cancel) and Skip leaves no partial folder.
    func testToolFailureIsAskedAndSkipLeavesNoPartial() async throws {
        try sandbox.createFile("b.tar", contents: CraftedArchives.tar([.init(path: "only.txt", contents: Data("1".utf8))]))
        var tuning = FileOpTuning()
        tuning.toolOverride = { _ in "/usr/bin/false" }   // the extracting tool only; listing always uses /usr/bin/tar
        let interaction = ScriptedInteraction(errors: [.skip])
        let (queue, journal) = makeQueue(interaction: interaction, tuning: tuning)
        let outcome = try await run(.extract(url("b.tar")), on: queue)
        XCTAssertEqual(interaction.askedErrors().map(\.url), [url("b.tar")])
        XCTAssertEqual(outcome.skipped.map(\.url), [url("b.tar")])
        XCTAssertEqual(names(root).filter { $0.contains(".macx-") }, [])
        XCTAssertFalse(exists(url("only.txt")))
        let left = await journal.entries()
        XCTAssertTrue(left.isEmpty)
    }

    /// The post-extraction walk: setuid cleared; an escaping symlink or a hard link to a file outside fails it.
    func testPostCheck() async throws {
        try file("p/sub/tool", "#!/bin/sh"); try sandbox.setMode("p/sub/tool", 0o4755)
        try sandbox.createSymlink("p/sub/ok", target: "../tool2")
        let p = url("p").path
        let clean = try await LanePool().perform(on: .unknown, .fileOp) { lane in ExtractJob.postCheck(p, lane: lane) }
        XCTAssertTrue(clean)
        XCTAssertEqual(lst(url("p/sub/tool")).st_mode & 0o7777, 0o755)

        try file("q/a.txt"); try sandbox.createSymlink("q/out", target: "../outside")
        let q = url("q").path
        let escaping = try await LanePool().perform(on: .unknown, .fileOp) { lane in ExtractJob.postCheck(q, lane: lane) }
        XCTAssertFalse(escaping)

        try file("outside/keep.txt", "keep"); try dir("r"); try sandbox.createHardLink("r/h", to: "outside/keep.txt")
        try file("r/a.txt"); try sandbox.createHardLink("r/b.txt", to: "r/a.txt")
        let r = url("r").path
        let linkedOut = try await LanePool().perform(on: .unknown, .fileOp) { lane in ExtractJob.postCheck(r, lane: lane) }
        XCTAssertFalse(linkedOut)
        try sandbox.remove("r/h")
        let linkedIn = try await LanePool().perform(on: .unknown, .fileOp) { lane in ExtractJob.postCheck(r, lane: lane) }
        XCTAssertTrue(linkedIn, "hard links among extracted files are fine")
        XCTAssertEqual(text(url("outside/keep.txt")), "keep")

        // QA round 1: links resolved through other links ("d/l1 -> .." then "l2 -> d/l1/..") leave the root.
        func check(_ name: String, _ links: [(String, String)]) async throws -> Bool {
            try dir("\(name)/d"); try sandbox.createSymlink("\(name)/d/l1", target: "..")
            for (path, target) in links { try sandbox.createSymlink("\(name)/\(path)", target: target) }
            let root = url(name).path
            return try await LanePool().perform(on: .unknown, .fileOp) { lane in ExtractJob.postCheck(root, lane: lane) }
        }
        let chainInside = try await check("c1", [])
        XCTAssertTrue(chainInside)
        let viaLinkInside = try await check("c2", [("l4", "d/l1/d/l1")])
        XCTAssertTrue(viaLinkInside)
        let chainOut = try await check("c3", [("l2", "d/l1/..")])
        XCTAssertFalse(chainOut)
        let chainToFile = try await check("c4", [("l3", "d/l1/../../outside/keep.txt")])
        XCTAssertFalse(chainToFile)
        let loop = try await check("c5", [("loop", "loop")])
        XCTAssertFalse(loop, "a link loop never resolves, so it is refused")
    }
}
private extension String { func leftPadded(_ n: Int) -> String { String(repeating: "0", count: max(0, n - count)) + self } }
