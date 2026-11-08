import XCTest
import Darwin
@testable import Core
import MacxFS

final class CopyTests: FileOpsTestCase {
    private func runWithFinalSnapshot(_ kind: JobKind, _ queue: FileOpQueue) async throws -> (JobOutcome, JobSnapshot?) {
        let consumer = Task { () -> JobSnapshot? in
            for await e in queue.events { if case .finished(let s, _) = e { return s } }
            return nil
        }
        let outcome = try await run(kind, on: queue)
        return (outcome, await consumer.value)
    }
    private func link(_ u: URL) -> String? { try? FileManager.default.destinationOfSymbolicLink(atPath: u.path) }

    func testCopyFileRecordsCreatedLocalChangeAndCloneBytes() async throws {
        let a = try bigFile("src/a.bin", bytes: 8 << 20)
        let d = try dir("d")
        let (queue, _) = makeQueue()
        let (outcome, final) = try await runWithFinalSnapshot(.copy(sources: [a], destination: d), queue)
        let copy = url("d/a.bin")
        XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: a))
        guard case .created(let u, _)? = outcome.record.actions.first else { return XCTFail("\(outcome.record)") }
        XCTAssertEqual(u, copy)
        XCTAssertEqual(outcome.created, [copy])
        XCTAssertEqual(outcome.localChanges.map(\.directory.path), [d.standardizedFileURL.path])
        XCTAssertEqual(outcome.localChanges.first?.added, ["a.bin"])
        XCTAssertEqual(outcome.localChanges.first?.select, ["a.bin"])
        XCTAssertEqual(final?.progress.bytesDone, 8 << 20, "a clone sends no callbacks; bytes are counted when copyfile returns")
        XCTAssertEqual(final?.progress.itemsDone, 1)
    }

    func testCopyTreePreservesStructure() async throws {
        try file("T/a", "A"); try file("T/sub/b", "B"); try dir("T/empty")
        let (queue, _) = makeQueue()
        _ = try await run(.copy(sources: [url("T")], destination: try dir("d")), on: queue)
        XCTAssertEqual(names(url("d/T")), ["a", "empty", "sub"])
        XCTAssertEqual(text(url("d/T/sub/b")), "B")
    }

    func testDuplicateUsesFinderNames() async throws {
        let a = try file("a.txt", "A"), f = try dir("folder")
        let (queue, _) = makeQueue()
        _ = try await run(.duplicate([a, f]), on: queue)
        _ = try await run(.duplicate([a]), on: queue)
        XCTAssertEqual(names(root).filter { !$0.hasPrefix(".") && $0 != "state" },
                       ["a copy 2.txt", "a copy.txt", "a.txt", "folder", "folder copy"])
    }

    func testCopyIntoSameFolderMakesCopies() async throws {
        let a = try file("d/a.txt", "A")
        let (queue, _) = makeQueue()
        let o = try await run(.copy(sources: [a], destination: url("d")), on: queue)
        XCTAssertEqual(names(url("d")), ["a copy.txt", "a.txt"])
        XCTAssertEqual(o.skipped, [])
    }

    /// Review Focus 1 at job level.
    func testCopyJobIntoOwnDescendantSkipsOnlyThatItem() async throws {
        try file("A/sub/x"); let b = try file("B", "b")
        let scripted = ScriptedInteraction(errors: [.skip])
        let (queue, _) = makeQueue(interaction: scripted)
        let o = try await run(.copy(sources: [url("A"), b], destination: url("A/sub")), on: queue)
        XCTAssertEqual(names(url("A/sub")), ["B", "x"])
        XCTAssertEqual(o.skipped, [SkippedItem(url: url("A"), reason: .intoItself)])
        XCTAssertEqual(scripted.askedErrors().map(\.kind), [.intoItself])
    }

    /// QA round 2: fts reports an unreadable folder twice (FTS_D, then FTS_DNR); the copy used to create the folder
    /// for the first before failing on the second, so Skip left an empty folder behind (and reported it created).
    func testSkippingAnUnreadableTopLevelFolderLeavesNothingBehind() async throws {
        let denied = try file("denied/s.txt", "x")
        XCTAssertEqual(chmod(denied.deletingLastPathComponent().path, 0), 0)
        defer { chmod(url("denied").path, 0o755) }
        let dest = try dir("dest")
        let scripted = ScriptedInteraction(errors: [.skip])
        let (queue, _) = makeQueue(interaction: scripted)
        let o = try await run(.copy(sources: [url("denied")], destination: dest), on: queue)
        XCTAssertEqual(scripted.askedErrors().map(\.kind), [.permissionDenied])
        XCTAssertEqual(o.skipped.map(\.url), [url("denied")])
        XCTAssertEqual(o.created, [], "a skipped item is never also created")
        XCTAssertEqual(names(dest), [], "no empty folder left at the destination")
    }

    func testSkippingAnUnreadableSubfolderLeavesNoEmptyCopyOfIt() async throws {
        try file("T/a", "A"); try file("T/closed/x", "X")
        XCTAssertEqual(chmod(url("T/closed").path, 0), 0)
        defer { chmod(url("T/closed").path, 0o755) }
        let scripted = ScriptedInteraction(errors: [.skip])
        let (queue, _) = makeQueue(interaction: scripted)
        _ = try await run(.copy(sources: [url("T")], destination: try dir("d")), on: queue)
        XCTAssertEqual(scripted.askedErrors().map(\.kind), [.permissionDenied])
        XCTAssertEqual(names(url("d/T")), ["a"])
    }

    /// Review Focus 2 (mandatory name).
    func testCopyTreeWithSymlinkLoopCopiesLinksAndTerminates() async throws {
        try file("A/f", "F"); try dir("A/sub")
        let absTarget = url("A").path
        for (target, rel) in [(".", "A/self"), ("..", "A/sub/up"), (absTarget, "A/abs"), ("nowhere", "A/broken"), ("sub", "A/sublink")] {
            XCTAssertEqual(symlink(target, url(rel).path), 0)
        }
        let (queue, _) = makeQueue()
        // Terminating at all is the check (a loop would hang the test); the exact copied tree below rules out a
        // copy that followed a link and recursed.
        let o = try await run(.copy(sources: [url("A")], destination: try dir("d")), on: queue)
        XCTAssertEqual(o.skipped, [])
        XCTAssertEqual(names(url("d/A")), ["abs", "broken", "f", "self", "sub", "sublink"])
        for (rel, target) in [("self", "."), ("sub/up", ".."), ("abs", absTarget), ("broken", "nowhere"), ("sublink", "sub")] {
            XCTAssertEqual(lst(url("d/A/\(rel)")).st_mode & S_IFMT, S_IFLNK, rel)
            XCTAssertEqual(link(url("d/A/\(rel)")), target, rel)
        }
    }

    func testDirectoryCopyPreservesMtimeModeAndLock() async throws {
        try file("T/ro/f"); try file("T/locked/g")
        var times = [timeval(tv_sec: 978_307_200, tv_usec: 0), timeval(tv_sec: 978_307_200, tv_usec: 0)]
        XCTAssertEqual(utimes(url("T/ro").path, &times), 0)
        XCTAssertEqual(utimes(url("T/locked").path, &times), 0)
        XCTAssertEqual(chmod(url("T/ro").path, 0o555), 0)
        XCTAssertEqual(lchflags(url("T/locked").path, UInt32(UF_IMMUTABLE)), 0)
        let (queue, _) = makeQueue()
        let o = try await run(.copy(sources: [url("T")], destination: try dir("d")), on: queue)
        XCTAssertEqual(o.skipped, [])
        let ro = lst(url("d/T/ro")), locked = lst(url("d/T/locked"))
        XCTAssertEqual(ro.st_mode & 0o7777, 0o555)
        XCTAssertEqual(ro.st_mtimespec.tv_sec, 978_307_200)
        XCTAssertEqual(locked.st_mtimespec.tv_sec, 978_307_200)
        XCTAssertNotEqual(locked.st_flags & UInt32(UF_IMMUTABLE), 0)
        XCTAssertTrue(exists(url("d/T/ro/f")))
        XCTAssertTrue(exists(url("d/T/locked/g")))
    }

    func testXattrsTagsAndACLPreservedWithoutClone() async throws {
        let f = try file("x.txt", "X")
        XCTAssertEqual(setxattr(f.path, "com.macexplorer.test", "v", 1, 0, XATTR_NOFOLLOW), 0)
        var rv = URLResourceValues(); rv.tagNames = ["Red"]
        var fu = f; try fu.setResourceValues(rv)
        let chmodA = Process()
        chmodA.executableURL = URL(filePath: "/bin/chmod")
        chmodA.arguments = ["+a", "everyone deny delete", f.path]
        try chmodA.run(); chmodA.waitUntilExit()
        XCTAssertEqual(chmodA.terminationStatus, 0)
        let copyPath = url("d/x.txt").path
        addTeardownBlock {   // the deny-delete ACL would otherwise block sandbox removal
            let strip = Process()
            strip.executableURL = URL(filePath: "/bin/chmod")
            strip.arguments = ["-N", f.path, copyPath]
            try? strip.run(); strip.waitUntilExit()
        }
        var tuning = FileOpTuning(); tuning.allowClone = false
        let (queue, _) = makeQueue(tuning: tuning)
        _ = try await run(.copy(sources: [f], destination: try dir("d")), on: queue)
        let c = url("d/x.txt")
        var buf = [UInt8](repeating: 0, count: 8)
        XCTAssertEqual(getxattr(c.path, "com.macexplorer.test", &buf, 8, 0, XATTR_NOFOLLOW), 1)
        XCTAssertEqual(try URL(filePath: c.path).resourceValues(forKeys: [.tagNamesKey]).tagNames, ["Red"])
        let acl = acl_get_link_np(c.path, ACL_TYPE_EXTENDED)
        XCTAssertNotNil(acl, "extended ACL copied")
        if let acl { acl_free(UnsafeMutableRawPointer(acl)) }
    }

    func testSparseFileStaysSparseWithoutClone() async throws {
        let s = try sandbox.createFile("sparse", contents: Data())
        let h = try FileHandle(forWritingTo: s)
        try h.seek(toOffset: 256 << 20); try h.write(contentsOf: Data([1])); try h.close()
        guard Int64(lst(s).st_blocks) * 512 < 1 << 20 else { throw XCTSkip("sandbox volume does not store sparse files") }
        var tuning = FileOpTuning(); tuning.allowClone = false
        let (queue, _) = makeQueue(tuning: tuning)
        _ = try await run(.copy(sources: [s], destination: try dir("d")), on: queue)
        let c = lst(url("d/sparse"))
        XCTAssertEqual(c.st_size, (256 << 20) + 1)
        XCTAssertLessThan(Int64(c.st_blocks) * 512, 4 << 20)
    }

    func testPauseAndResumeMidFile() async throws {
        let big = try bigFile("big", bytes: 64 << 20)
        let d = try dir("d")
        let reached = EventLog()
        let proceed = DispatchSemaphore(value: 0)
        var tuning = FileOpTuning(copyChunkBytes: 1 << 20, faultHook: { point, _ in
            if point == .midCopyChunk, !reached.all.contains("chunk") { reached.add("chunk"); proceed.wait() }
        })
        tuning.allowClone = false
        let (queue, _) = makeQueue(tuning: tuning)
        let id = await queue.enqueue(request(.copy(sources: [big], destination: d)))
        await waitUntil { reached.all.contains("chunk") }
        await queue.pause(id)
        // The copyfile callback reports the chunk's bytes before the hook, and goes straight from the hook to its
        // pause checkpoint; the pause is set before the hook returns, so bytesDone is final from here on.
        let s1 = await queue.snapshots().first!
        proceed.signal()
        try await Task.sleep(for: .milliseconds(200))                    // negative check: nothing may move
        let s2 = await queue.snapshots().first!
        XCTAssertEqual(s1.state, .paused)
        XCTAssertEqual(s1.progress.bytesDone, s2.progress.bytesDone, "no bytes copied while paused")
        XCTAssertLessThan(s2.progress.bytesDone, 64 << 20)
        await queue.resume(id)
        let o = await queue.outcome(of: id)
        XCTAssertFalse(o.wasCancelled)
        XCTAssertEqual(try Data(contentsOf: url("d/big")), try Data(contentsOf: big))
    }

    /// Slice Review Focus 4.
    func testCancelMidFileRemovesPartialFileAndFinalizesDirectories() async throws {
        try file("T/a", "A")
        try bigFile("T/z-big", bytes: 64 << 20)
        XCTAssertEqual(chmod(url("T").path, 0o750), 0)
        let reached = EventLog()
        let proceed = DispatchSemaphore(value: 0)
        var tuning = FileOpTuning(faultHook: { point, _ in
            if point == .midCopyChunk, !reached.all.contains("chunk") { reached.add("chunk"); proceed.wait() }
        })
        tuning.allowClone = false
        let (queue, _) = makeQueue(tuning: tuning)
        let id = await queue.enqueue(request(.copy(sources: [url("T")], destination: try dir("d"))))
        await waitUntil { reached.all.contains("chunk") }
        await queue.cancel(id)
        proceed.signal()
        let o = await queue.outcome(of: id)
        XCTAssertTrue(o.wasCancelled)
        XCTAssertEqual(names(url("d/T")), ["a"], "the interrupted file is removed")
        XCTAssertEqual(lst(url("d/T")).st_mode & 0o7777, 0o750, "directory finalized, not left at 0700")
        guard case .created(let u, _)? = o.record.actions.first else { return XCTFail() }
        XCTAssertEqual(u, url("d/T"))
    }

    /// A failed copyfile unlinks the destination only when it is the file copyfile created.
    func testFailedCopyNeverUnlinksADestinationItDidNotCreate() async throws {
        let src = try file("src", "S")
        XCTAssertEqual(chmod(src.path, 0), 0)                             // open(src) fails before dst is touched
        let dst = try file("dst", "someone else's")                       // appeared after our existence check
        let control = JobControl()
        let (srcPath, dstPath) = (src.path, dst.path)
        let r = try await LanePool().perform(on: .unknown, .fileOp) { lane in
            CopyEngine.copyFile(from: srcPath, to: dstPath, expectedSize: 1, clone: false, chunkBytes: 1 << 20,
                                lane: lane, control: control, onBytes: { _ in }, onChunk: {})
        }
        XCTAssertEqual(r, .failed(EACCES))
        XCTAssertEqual(text(dst), "someone else's")
    }

    /// A clone writes no data: its bytes are reported as cloned, so rate and fraction ignore them (QA round 2).
    func testCloneReportsItsBytesAsCloned() async throws {
        let src = try file("src", String(repeating: "x", count: 100_000))
        let dst = url("cloned")
        let control = JobControl()
        let (srcPath, dstPath) = (src.path, dst.path)
        let reported = try await LanePool().perform(on: .unknown, .fileOp) { lane -> (Int64, Int64) in
            var plain: Int64 = 0, cloned: Int64 = 0
            let r = CopyEngine.copyFile(from: srcPath, to: dstPath, expectedSize: 100_000, clone: true, chunkBytes: 1 << 20,
                                        lane: lane, control: control, onBytes: { plain += $0 }, onChunk: {},
                                        onCloned: { cloned += $0 })
            precondition(r == .copied)
            return (plain, cloned)
        }
        XCTAssertEqual(reported.0, 0, "no bytes written")
        XCTAssertEqual(reported.1, 100_000, "the sandbox is on APFS: copyfile clones")
    }

    /// Another process takes the target between the conflict check and the copy; Cancel must not record its item.
    func testCancelledCopyNeverRecordsAnItemItDidNotCreate() async throws {
        let a = try file("src/a", "mine")
        let d = try dir("d")
        let foreign = try file("d/a", "someone else's")
        let lanes = LanePool()
        let item = try await lanes.perform(on: .unknown, .fileOp) { lane in
            Planner.plan(sources: [a], destination: nil, mode: .copy, forceCrossVolume: false, lane: lane).items[0]
        }
        let scripted = ScriptedInteraction(errors: [.cancel])
        let ctx = JobContext(id: JobID(), request: request(.copy(sources: [a], destination: d)), lanes: lanes,
                             trash: SandboxTrash(directory: trashDir), journal: Journal(fileURL: journalURL),
                             interaction: scripted, tuning: FileOpTuning())
        let r = await CopyJob.copyItem(ctx, item, to: foreign)
        XCTAssertEqual(r, .cancelled)
        XCTAssertEqual(scripted.askedErrors().count, 1)
        XCTAssertEqual(ctx.outcome().record.actions, [])
        XCTAssertEqual(ctx.outcome().created, [])
        XCTAssertEqual(text(foreign), "someone else's")
    }

    func testUnreadableEntryReportsPermissionAndOtherEntriesCopy() async throws {
        try file("T/a"); try file("T/secret"); try file("T/c")
        XCTAssertEqual(chmod(url("T/secret").path, 0o000), 0)
        let scripted = ScriptedInteraction(errors: [.skip])
        var tuning = FileOpTuning(); tuning.allowClone = false
        let (queue, _) = makeQueue(interaction: scripted, tuning: tuning)
        let o = try await run(.copy(sources: [url("T")], destination: try dir("d")), on: queue)
        XCTAssertEqual(scripted.askedErrors().map(\.kind), [.permissionDenied])
        XCTAssertEqual(names(url("d/T")), ["a", "c"])
        XCTAssertEqual(o.skipped.map(\.url), [url("T/secret")])
    }

    func testConflictAskedAndSkipKeepsDestination() async throws {
        let a = try file("src/a", "new"); try file("d/a", "old")
        let scripted = ScriptedInteraction()
        let (queue, _) = makeQueue(interaction: scripted)
        let o = try await run(.copy(sources: [a], destination: url("d")), on: queue)
        XCTAssertEqual(text(url("d/a")), "old")
        XCTAssertEqual(o.skipped, [SkippedItem(url: a, reason: nil)])
        let asked = scripted.askedConflicts()
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked.first?.isFolderMerge, false)
        XCTAssertEqual(asked.first?.knownRemaining, 1)
        XCTAssertEqual(asked.first?.pair.destination.url, url("d/a"))
    }

    func testConflictKeepBoth() async throws {
        let a = try file("src/a.txt", "new"); try file("d/a.txt", "old")
        let (queue, _) = makeQueue(interaction: ScriptedInteraction(conflicts: [.one(.keepBoth)]))
        _ = try await run(.copy(sources: [a], destination: url("d")), on: queue)
        XCTAssertEqual(text(url("d/a.txt")), "old")
        XCTAssertEqual(text(url("d/a 2.txt")), "new")
    }

    func testCopyToSmallImageAsksForSpaceAndCopiesNothingWhenDeclined() async throws {
        let mnt = try image(.hfsPlus, sizeMB: 16)
        let big = try bigFile("big", bytes: 40 << 20)
        let scripted = ScriptedInteraction(space: [false])
        let (queue, _) = makeQueue(interaction: scripted)
        let o = try await run(.copy(sources: [big], destination: mnt), on: queue)
        XCTAssertTrue(o.wasCancelled)
        XCTAssertEqual(scripted.askedSpace().count, 1)
        XCTAssertFalse(names(mnt).contains("big"))
    }
}
