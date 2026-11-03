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

    /// Review Focus 2 (mandatory name).
    func testCopyTreeWithSymlinkLoopCopiesLinksAndTerminates() async throws {
        try file("A/f", "F"); try dir("A/sub")
        let absTarget = url("A").path
        for (target, rel) in [(".", "A/self"), ("..", "A/sub/up"), (absTarget, "A/abs"), ("nowhere", "A/broken"), ("sub", "A/sublink")] {
            XCTAssertEqual(symlink(target, url(rel).path), 0)
        }
        let (queue, _) = makeQueue()
        let start = ContinuousClock.now
        let o = try await run(.copy(sources: [url("A")], destination: try dir("d")), on: queue)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(10))
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
        let id = await queue.enqueue(JobRequest(.copy(sources: [big], destination: d)))
        await waitUntil { reached.all.contains("chunk") }
        await queue.pause(id)
        proceed.signal()
        try await Task.sleep(for: .milliseconds(300))
        let s1 = await queue.snapshots().first!
        try await Task.sleep(for: .milliseconds(200))
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
        let id = await queue.enqueue(JobRequest(.copy(sources: [url("T")], destination: try dir("d"))))
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
