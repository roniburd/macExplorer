import XCTest
import Darwin
import Synchronization
@testable import Core
import MacxFS
import MacxFixtures

/// P4-09: archive formats, the process runner and the compress job. Every file lives in the test's sandbox.
final class CompressTests: FileOpsTestCase {
    private func unzipList(_ zip: URL) throws -> [String] {
        let out = try ProcessRunnerTestTool.run("/usr/bin/zipinfo", ["-1", zip.path])
        return out.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("__MACOSX") }.sorted()
    }

    /// Partial archives and staging folders the job leaves next to the sources (none once it is done).
    private func leftovers() -> [String] { names(root).filter { $0.contains(".macx-") } }

    /// Random bytes, so deflate can't finish them quickly (the cancel and pause tests need a running tool).
    @discardableResult private func randomFile(_ rel: String, bytes: Int) throws -> URL {
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, bytes) }
        return try sandbox.createFile(rel, contents: data)
    }

    func testFormatDetectionAndNaming() {
        XCTAssertEqual(ArchiveFormat.detect(byName: "a.ZIP"), .zip)
        XCTAssertEqual(ArchiveFormat.detect(byName: "a.tar.gz"), .tarGzip)
        XCTAssertEqual(ArchiveFormat.detect(byName: "a.tgz"), .tarGzip)
        XCTAssertEqual(ArchiveFormat.detect(byName: "a.tbz2"), .tarBzip2)
        XCTAssertEqual(ArchiveFormat.detect(byName: "a.txz"), .tarXz)
        XCTAssertEqual(ArchiveFormat.detect(byName: "a.gz"), .gzip)
        XCTAssertEqual(ArchiveFormat.detect(byName: "a.aar"), .appleArchive)
        XCTAssertEqual(ArchiveFormat.detect(byName: "a.tar"), .tar)
        XCTAssertNil(ArchiveFormat.detect(byName: "a.rar"))
        XCTAssertNil(ArchiveFormat.detect(byName: ".zip"))
        XCTAssertEqual(ArchiveFormat.detect(magic: Data([0x50, 0x4B, 0x03, 0x04]), name: "a.bin"), .zip)
        XCTAssertEqual(ArchiveFormat.detect(magic: Data([0x1F, 0x8B, 0x08]), name: "a.tar.gz"), .tarGzip)
        XCTAssertEqual(ArchiveFormat.detect(magic: Data([0x1F, 0x8B, 0x08]), name: "notes.gz"), .gzip)
        XCTAssertEqual(ArchiveFormat.detect(magic: Data("AA01".utf8), name: "x"), .appleArchive)
        XCTAssertEqual(ArchiveFormat.detect(magic: Data("pbze".utf8), name: "x"), .appleArchive)
        XCTAssertNil(ArchiveFormat.detect(magic: Data("hello".utf8), name: "x.zip"))
        XCTAssertEqual(ArchiveFormat.baseName(stripping: "photos.tar.gz"), "photos")
        XCTAssertEqual(ArchiveFormat.baseName(stripping: "a.b.zip"), "a.b")
        XCTAssertEqual(ArchiveFormat.baseName(stripping: "notes.txt"), "notes.txt")
        XCTAssertEqual(ArchiveNaming.outputName(for: [url("a.txt")], format: .zip), "a.txt.zip")
        XCTAssertEqual(ArchiveNaming.outputName(for: [url("photos")], format: .appleArchive), "photos.aar")
        XCTAssertEqual(ArchiveNaming.outputName(for: [url("a"), url("b")], format: .appleArchive), "Archive.aar")
        XCTAssertTrue(ArchiveFormat.zip.canCreate); XCTAssertTrue(ArchiveFormat.appleArchive.canCreate)
        XCTAssertFalse(ArchiveFormat.tarGzip.canCreate)
    }

    func testCompressJobDescriptionAndVerb() {
        let kind = JobKind.compress([url("a.txt"), url("b.txt")], .zip)
        XCTAssertEqual(kind.allURLs, [url("a.txt"), url("b.txt")])
        XCTAssertEqual(kind.jobDescription, JobDescription(verb: .compressing, itemCount: 2, firstItemName: "a.txt",
                                                           sourceFolderName: root.lastPathComponent, destinationFolderName: nil))
    }

    func testProcessRunnerCapturesAndCancels() async throws {
        let r = try await LanePool().perform(on: .unknown, .fileOp) { lane in
            try ProcessRunner.run("/bin/echo", ["hi"], output: .capture, context: lane, isPaused: { false }, onStderrLine: { _ in })
        }
        XCTAssertEqual(r.status, 0); XCTAssertEqual(String(decoding: r.stdout, as: UTF8.self), "hi\n")
        let lines = Mutex<[String]>([])
        let e = try await LanePool().perform(on: .unknown, .fileOp) { lane in
            try ProcessRunner.run("/bin/sh", ["-c", "echo one >&2; printf 'two\\nlast' >&2; exit 3"], context: lane,
                                  isPaused: { false }, onStderrLine: { line in lines.withLock { $0.append(line) } })
        }
        XCTAssertEqual(e.status, 3)
        XCTAssertEqual(lines.withLock { $0 }, ["one", "two", "last"])
        XCTAssertEqual(e.stderrTail, "one\ntwo\nlast")
        let task = Task {
            try await LanePool().perform(on: .unknown, .fileOp) { lane in
                try ProcessRunner.run("/bin/sleep", ["30"], context: lane, isPaused: { false }, onStderrLine: { _ in })
            }
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let start = ContinuousClock.now
        do { _ = try await task.value; XCTFail("expected cancellation") } catch { XCTAssertEqual(error as? LaneError, .cancelled) }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(3))
    }

    func testProcessRunnerFileOutputIsExclusive() async throws {
        let existing = try file("out.txt")
        do {
            _ = try await LanePool().perform(on: .unknown, .fileOp) { lane in
                try ProcessRunner.run("/bin/echo", ["x"], output: .file(existing), context: lane, isPaused: { false }, onStderrLine: { _ in })
            }
            XCTFail("expected EEXIST")
        } catch { XCTAssertEqual((error as? ProcessRunnerError)?.code, EEXIST) }
        XCTAssertEqual(text(existing), "x")
        let fresh = url("fresh.txt")
        let r = try await LanePool().perform(on: .unknown, .fileOp) { lane in
            try ProcessRunner.run("/bin/echo", ["written"], output: .file(fresh), context: lane, isPaused: { false }, onStderrLine: { _ in })
        }
        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(text(fresh), "written\n")
        let missing = url("no-such-tool").path
        do {
            _ = try await LanePool().perform(on: .unknown, .fileOp) { lane in
                try ProcessRunner.run(missing, [], context: lane, isPaused: { false }, onStderrLine: { _ in })
            }
            XCTFail("expected ENOENT")
        } catch { XCTAssertEqual((error as? ProcessRunnerError)?.code, ENOENT) }
    }

    func testCompressSingleFolderZip() async throws {
        try file("photos/a.jpg"); try file("photos/sub/b.jpg")
        let (queue, journal) = makeQueue()
        let outcome = try await run(.compress([url("photos")], .zip), on: queue)
        XCTAssertEqual(outcome.created.map(\.lastPathComponent), ["photos.zip"])
        XCTAssertEqual(try unzipList(url("photos.zip")), ["photos/", "photos/a.jpg", "photos/sub/", "photos/sub/b.jpg"])
        XCTAssertEqual(leftovers(), [])
        let entries = await journal.entries()
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(outcome.record.verb, .compressing)
        XCTAssertEqual(outcome.localChanges.first?.select, ["photos.zip"])
        XCTAssertEqual(names(url("photos")), ["a.jpg", "sub"], "sources are left alone")
    }

    func testCompressMultipleItemsPutsThemAtTopLevelAndAppleArchiveRoundTrips() async throws {
        try file("a.txt", "A"); try file("b.txt", "B")
        let (queue, _) = makeQueue()
        _ = try await run(.compress([url("a.txt"), url("b.txt")], .zip), on: queue)
        XCTAssertEqual(try unzipList(url("Archive.zip")), ["a.txt", "b.txt"])
        let aar = try await run(.compress([url("a.txt"), url("b.txt")], .appleArchive), on: queue)
        XCTAssertEqual(aar.created.map(\.lastPathComponent), ["Archive.aar"])
        try dir("check")
        _ = try ProcessRunnerTestTool.run("/usr/bin/aa", ["extract", "-i", url("Archive.aar").path, "-d", url("check").path])
        XCTAssertEqual(text(url("check/a.txt")), "A"); XCTAssertEqual(text(url("check/b.txt")), "B")
        XCTAssertEqual(names(url("check")), ["a.txt", "b.txt"])
        XCTAssertEqual(leftovers(), [])
        XCTAssertEqual(names(root).filter { !$0.hasPrefix(".") && $0 != "state" }, ["Archive.aar", "Archive.zip", "a.txt", "b.txt", "check"])
    }

    func testCompressNamesNextFreeAndCancelLeavesNothing() async throws {
        try file("a.txt"); try file("b.txt"); try file("Archive.zip", "taken"); try file("Archive 2.zip", "taken")
        let (queue, journal) = makeQueue()
        let outcome = try await run(.compress([url("a.txt"), url("b.txt")], .zip), on: queue)
        XCTAssertEqual(outcome.created.map(\.lastPathComponent), ["Archive 3.zip"])
        XCTAssertEqual(text(url("Archive.zip")), "taken")
        XCTAssertEqual(text(url("Archive 2.zip")), "taken")

        try randomFile("big/blob1", bytes: 48 << 20); try randomFile("big/blob2", bytes: 48 << 20)
        let started = expectation(description: "tool started")
        let holder = QueueHolder()
        let tuning = FileOpTuning(faultHook: { point, id in
            if point == .archiveToolStarted { started.fulfill(); Task { await holder.queue?.cancel(id) } }
        })
        let (q2, j2) = makeQueue(tuning: tuning)
        holder.queue = q2
        let cancelled = try await run(.compress([url("big")], .zip), on: q2)
        await fulfillment(of: [started], timeout: 10)
        XCTAssertTrue(cancelled.wasCancelled)
        XCTAssertTrue(cancelled.created.isEmpty)
        XCTAssertTrue(cancelled.record.actions.isEmpty)
        XCTAssertFalse(exists(url("big.zip")))
        XCTAssertEqual(leftovers(), [])
        let left2 = await j2.entries(), left1 = await journal.entries()
        XCTAssertTrue(left2.isEmpty); XCTAssertTrue(left1.isEmpty)
    }

    /// A job paused while its tool runs (SIGSTOP) holds journaled partials that launch recovery removes; cancel
    /// then resumes and ends the tool.
    func testPausedCompressJournalsPartialsThatRecoveryRemoves() async throws {
        try randomFile("x/blob1", bytes: 48 << 20); try file("y.txt")
        let paused = expectation(description: "paused")
        let holder = QueueHolder()
        let tuning = FileOpTuning(faultHook: { point, id in
            guard point == .archiveToolStarted else { return }
            Task { await holder.queue?.pause(id); paused.fulfill() }
        })
        let (queue, journal) = makeQueue(tuning: tuning)
        holder.queue = queue
        let id = await queue.enqueue(request(.compress([url("x"), url("y.txt")], .zip)))
        await fulfillment(of: [paused], timeout: 10)
        let entries = await journal.entries()
        let partials = entries.compactMap { if case .partial(_, let u) = $0 { u } else { nil } }
        XCTAssertEqual(partials.count, 2, "\(entries)")
        for p in partials {
            XCTAssertTrue(PartialName.isPartial(p.lastPathComponent), p.lastPathComponent)
            XCTAssertEqual(p.deletingLastPathComponent().standardizedFileURL.path, root.standardizedFileURL.path)
        }
        XCTAssertTrue(entries.contains { if case .jobStarted = $0 { true } else { false } })
        let report = try await LanePool().perform(on: .unknown, .fileOp) { lane in LaunchRecovery.recover(entries, lane) }
        XCTAssertFalse(report.removedPartials.isEmpty)
        XCTAssertEqual(leftovers(), [])
        await queue.cancel(id)
        let outcome = await queue.outcome(of: id)
        XCTAssertTrue(outcome.wasCancelled)
        XCTAssertEqual(leftovers(), [])
        XCTAssertFalse(exists(url("Archive.zip")))
        XCTAssertEqual(names(url("x")), ["blob1"])
    }

    func testUndoTrashesTheArchive() async throws {
        try file("a.txt")
        let (queue, _) = makeQueue()
        let outcome = try await run(.compress([url("a.txt")], .zip), on: queue)
        XCTAssertEqual(outcome.record.actions.count, 1)
        _ = try await run(.undo(outcome.record), on: queue)
        XCTAssertFalse(exists(url("a.txt.zip"))); XCTAssertTrue(exists(url("a.txt")))
        XCTAssertEqual(names(trashDir).count, 1, "the archive went to the (sandbox) Trash")
    }

    func testToolFailureIsAskedAndSkipLeavesNoPartial() async throws {
        try file("a.txt")
        var tuning = FileOpTuning(); tuning.toolOverride = { _ in "/usr/bin/false" }
        let interaction = ScriptedInteraction(errors: [.skip])
        let (queue, journal) = makeQueue(interaction: interaction, tuning: tuning)
        let outcome = try await run(.compress([url("a.txt")], .zip), on: queue)
        XCTAssertEqual(interaction.askedErrors().count, 1)
        XCTAssertEqual(interaction.askedErrors().first?.url, url("a.txt"))
        XCTAssertTrue(outcome.created.isEmpty)
        XCTAssertEqual(outcome.skipped.map(\.url), [url("a.txt")])
        XCTAssertEqual(leftovers(), [])
        let entries = await journal.entries()
        XCTAssertTrue(entries.isEmpty)
    }

    func testToolFailureRetryThenCancelAndNoSpaceMapping() async throws {
        try file("a.txt"); try file("b.txt")
        var tuning = FileOpTuning()
        tuning.toolOverride = { _ in "/bin/sh" }   // sh can't run ditto's arguments: it fails every time
        let interaction = ScriptedInteraction(errors: [.retry, .cancel])
        let (queue, _) = makeQueue(interaction: interaction, tuning: tuning)
        let outcome = try await run(.compress([url("a.txt"), url("b.txt")], .zip), on: queue)
        XCTAssertEqual(interaction.askedErrors().count, 2)
        XCTAssertTrue(outcome.wasCancelled)
        XCTAssertEqual(leftovers(), [])
        XCTAssertEqual(CompressJob.errorKind(stderrTail: "ditto: x: No space left on device\n", status: 1),
                       .noSpace(needed: nil, available: nil))
        XCTAssertEqual(CompressJob.errorKind(stderrTail: "first\nditto: broken\n", status: 1), .other(code: EIO, message: "ditto: broken"))
        XCTAssertEqual(CompressJob.errorKind(stderrTail: "", status: 2), .other(code: EIO, message: "exit 2"))
    }

    func testSourcesInDifferentFoldersGoNextToTheFirst() async throws {
        try file("one/a.txt", "A"); try file("two/b.txt", "B")
        let (queue, _) = makeQueue()
        let outcome = try await run(.compress([url("one/a.txt"), url("two/b.txt")], .zip), on: queue)
        XCTAssertEqual(outcome.created.map { $0.standardizedFileURL.path }, [url("one/Archive.zip").standardizedFileURL.path])
        XCTAssertEqual(try unzipList(url("one/Archive.zip")), ["a.txt", "b.txt"])
        XCTAssertEqual(names(url("one")), ["Archive.zip", "a.txt"])
        XCTAssertEqual(names(url("two")), ["b.txt"])
    }
}

/// Tiny synchronous runner for checking results in tests (not lane code; harness I/O rule).
enum ProcessRunnerTestTool {
    static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process(); p.executableURL = URL(filePath: tool); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        try p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

final class QueueHolder: Sendable {
    private let storage = Mutex<FileOpQueue?>(nil)
    var queue: FileOpQueue? {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}
