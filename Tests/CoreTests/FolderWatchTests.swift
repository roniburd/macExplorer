@testable import Core
import Darwin
import Foundation
import MacxFixtures
@testable import MacxFS
import XCTest

/// FolderModel + watcher (§4.3): buffering during reads, incremental patches, one re-read plus one pending,
/// relocation; then real FSEvents bursts, atomic saves, hard links and a name-identity (exFAT) volume.
@MainActor
final class FolderWatchTests: XCTestCase {
    private let done = ReadEvent.completed(ReadSummary(entryCount: 0, degradedCount: 0, usedFallback: false, elapsed: .zero))

    private func watcher(_ w: FolderTestWorld) throws -> RecordingWatcher { try XCTUnwrap(w.watchers.last) }

    // MARK: Scripted watcher events

    func testItemsArePatchedIncrementally() async throws {
        let w = try await FolderTestWorld.make(self)
        try w.dir("inc")
        try w.file("inc/a.txt")
        let m = try await w.open("inc")
        let log = EventLog(m)
        try w.file("inc/b.txt")
        try w.remove("inc/a.txt")
        try watcher(w).send(.items(["b.txt", "a.txt"]))
        try await w.waitUntil("patched") { m.rowNames == ["b.txt"] }
        XCTAssertFalse(log.changeSets.contains(.reset), "after complete only incremental change sets")
        XCTAssertEqual(m.state, .complete)
        XCTAssertEqual(log.states, [])
    }

    /// Fails the in-flight re-read so the model is in .error with its watcher still running, then retries.
    private func retryingModel(_ w: FolderTestWorld, _ reads: ScriptedReads) async throws -> FolderModel {
        try w.dir("buf")
        try w.file("buf/a.txt")
        let m = try await w.open("buf")
        m.readSource = reads.source()
        m.refresh()
        try await w.waitUntil("re-read") { reads.reads.count == 1 }
        reads.last.continuation.yield(.failed(ReadFailure(code: EIO, stage: .read)))
        try await w.waitUntil("error") { m.state == .error(.other(EIO)) }
        m.retry()
        try await w.waitUntil("retry read") { reads.reads.count == 2 }
        XCTAssertEqual(m.state, .loading)
        return m
    }

    func testItemsDuringAReadAreBufferedAndAppliedAfterComplete() async throws {
        let w = try await FolderTestWorld.make(self)
        let reads = ScriptedReads()
        let m = try await retryingModel(w, reads)
        try w.file("buf/b.txt")
        try watcher(w).send(.items(["b.txt"]))
        await w.settle()
        XCTAssertEqual(m.rowCount, 0, "nothing is patched while the listing streams")
        let gen = reads.last.generation
        reads.last.continuation.yield(.batch(TestBatch.files(gen, ["a.txt"], firstID: 50)))
        reads.last.continuation.yield(done)
        try await w.waitUntil("buffered patch applied") { m.rowNames == ["a.txt", "b.txt"] }
        XCTAssertEqual(reads.reads.count, 2, "items never cost a re-read")
    }

    func testRescanDuringAReadBecomesOneRereadAfterComplete() async throws {
        let w = try await FolderTestWorld.make(self)
        let reads = ScriptedReads()
        let m = try await retryingModel(w, reads)
        for _ in 0..<3 { try watcher(w).send(.fullRescan) }
        try watcher(w).send(.items(["x"]))
        await w.settle()
        reads.last.continuation.yield(.batch(TestBatch.files(reads.last.generation, ["a.txt"], firstID: 50)))
        reads.last.continuation.yield(done)
        try await w.waitUntil("one re-read") { reads.reads.count == 3 }
        XCTAssertEqual(m.state, .complete, "a re-read never returns the model to loading")
        reads.last.continuation.yield(.batch(TestBatch.files(reads.last.generation, ["a.txt"], firstID: 50)))
        reads.last.continuation.yield(done)
        await w.settle(.milliseconds(150))
        XCTAssertEqual(reads.reads.count, 3)
    }

    func testFullRescansCoalesceToOneRereadPlusOnePending() async throws {
        let w = try await FolderTestWorld.make(self)
        try w.dir("rr")
        try w.file("rr/a")
        let m = try await w.open("rr")
        let reads = ScriptedReads()
        m.readSource = reads.source()
        for _ in 0..<5 { try watcher(w).send(.fullRescan) }
        try await w.waitUntil("first re-read") { reads.reads.count == 1 }
        await w.settle()
        XCTAssertEqual(reads.reads.count, 1, "at most one runs")
        reads.last.continuation.yield(.batch(TestBatch.files(reads.last.generation, ["a", "b"], firstID: 70)))
        reads.last.continuation.yield(done)
        try await w.waitUntil("pending re-read") { reads.reads.count == 2 }
        XCTAssertEqual(m.rowNames, ["a", "b"])
        reads.last.continuation.yield(.batch(TestBatch.files(reads.last.generation, ["a", "b"], firstID: 70)))
        reads.last.continuation.yield(done)
        await w.settle(.milliseconds(150))
        XCTAssertEqual(reads.reads.count, 2, "the pending one absorbed the later events")
        XCTAssertEqual(m.state, .complete)
    }

    func testRootRemovedRelocatesToTheNearestExistingAncestor() async throws {
        let w = try await FolderTestWorld.make(self)
        try w.dir("a")
        try w.dir("a/b")
        try w.dir("a/b/c")
        let m = try await w.open("a/b/c")
        let log = EventLog(m)
        guard rmdir(w.url("a/b/c").path) == 0, rmdir(w.url("a/b").path) == 0 else { return XCTFail("rmdir") }
        let rec = try watcher(w)
        rec.send(.rootChanged)
        try await w.waitUntil("relocate") { !log.relocations.isEmpty }
        let (to, reason) = try XCTUnwrap(log.relocations.first)
        XCTAssertEqual(ChangeBus.key(for: to), ChangeBus.key(for: w.url("a")))
        XCTAssertEqual(reason, .movedOrDeleted(name: "c"))
        XCTAssertEqual(rec.events, ["start", "stop"], "the watcher stops")
        rec.send(.rootChanged)
        await w.settle()
        XCTAssertEqual(log.relocations.count, 1, "relocates once")
    }

    func testRootChangedWhileTheFolderStillExistsRereads() async throws {
        let w = try await FolderTestWorld.make(self)
        try w.dir("still")
        let m = try await w.open("still")
        let log = EventLog(m)
        try w.file("still/new.txt")
        try watcher(w).send(.rootChanged)
        try await w.waitUntil("re-read") { m.rowNames == ["new.txt"] }
        XCTAssertTrue(log.relocations.isEmpty)
    }

    func testVolumeGoneGoesHome() async throws {
        let w = try await FolderTestWorld.make(self)
        try w.dir("vol")
        try w.dir("vol/x")
        w.scanner.addVolume("test-vol", at: w.url("vol"))
        await w.volumes.refresh()
        let m = try await w.open("vol/x")
        XCTAssertEqual(m.volume?.id, VolumeID(raw: "test-vol"))
        let log = EventLog(m)
        let rec = try watcher(w)
        w.scanner.removeVolume("test-vol")
        await w.volumes.refresh()
        try await w.waitUntil("home") { !log.relocations.isEmpty }
        let (to, reason) = try XCTUnwrap(log.relocations.first)
        XCTAssertEqual(to, w.sandbox.root)
        XCTAssertEqual(reason, .volumeGone)
        XCTAssertEqual(rec.events, ["start", "stop"])
    }

    // MARK: Real FSEvents (sandbox only)

    private func realWorld(caps: VolumeCapabilities? = nil) async throws -> FolderTestWorld {
        let w: FolderTestWorld
        if let caps { w = try await FolderTestWorld.make(self, caps: caps) } else { w = try await FolderTestWorld.make(self) }
        w.realWatcher = true
        return w
    }

    func testBurstOfFilesEndsWithEveryRow() async throws {
        let w = try await realWorld()
        try w.dir("burst")
        let m = try await w.open("burst")
        try await Task.sleep(for: .milliseconds(200))
        for i in 0..<1_000 { try w.file("burst/f\(i)") }
        try await w.waitUntil("all rows", timeout: .seconds(20)) { m.rowCount == 1_000 }
        XCTAssertEqual(m.state, .complete)
        XCTAssertEqual(Set(m.rowNames).count, 1_000)
    }

    func testAtomicSaveKeepsSelectionOnTheReplacement() async throws {
        let w = try await realWorld()
        try w.dir("doc")
        try w.file("doc/report.txt", "v1")
        try w.file("doc/other.txt")
        let m = try await w.open("doc")
        m.select(.names(["report.txt"]))
        let old = m.identity(atRow: try XCTUnwrap(m.row(named: "report.txt")))
        try await Task.sleep(for: .milliseconds(200))
        try w.file("doc/.report.txt.sb-tmp", "v2 longer")
        try w.rename("doc/.report.txt.sb-tmp", "doc/report.txt")
        try await w.waitUntil("replacement") {
            m.row(named: "report.txt").map { m.identity(atRow: $0) != old } ?? false
        }
        try await w.waitUntil("temp gone") { m.rowNames == ["other.txt", "report.txt"] }
        XCTAssertEqual(m.selectedNames, ["report.txt"], "selection moved to the new identity")
        XCTAssertEqual(m.entry(atRow: try XCTUnwrap(m.row(named: "report.txt"))).size, 9)
    }

    func testHardLinkIsASecondRowAndUnlinkKeepsTheFirst() async throws {
        let w = try await realWorld()
        try w.dir("hl")
        try w.file("hl/a.txt")
        let m = try await w.open("hl")
        try await Task.sleep(for: .milliseconds(200))
        _ = try w.sandbox.createHardLink("hl/b.txt", to: "hl/a.txt")
        try await w.waitUntil("link row") { m.rowNames == ["a.txt", "b.txt"] }
        XCTAssertNotEqual(m.identity(atRow: 0), m.identity(atRow: 1), "each link is its own row")
        try w.remove("hl/b.txt")
        try await w.waitUntil("unlinked") { m.rowNames == ["a.txt"] }
    }

    /// exFAT has no stable file IDs: rows are keyed by name, so an outside rename is remove + insert.
    func testExternalRenameOnAnExFATImage() async throws {
        try XCTSkipUnless(DiskImage.isAvailable, "hdiutil")
        let w = try await realWorld(caps: VolumeCapabilities(idStable: false, renameExcl: false, clone: false, caseSensitive: false))
        let image = try DiskImage.create(in: w.sandbox, format: .exfat, sizeMB: 16) { mount in
            try Data("x".utf8).write(to: mount.appending(path: "old.txt"))
        }
        defer { try? image.detach() }
        let m = w.model(image.mountPoint)
        m.start()
        try await w.waitUntil("complete") { m.state == .complete }
        guard case .name = m.store.identityMode else { return XCTFail("name identity on a non-idStable volume") }
        XCTAssertEqual(m.rowNames, ["old.txt"])
        let log = EventLog(m)
        try await Task.sleep(for: .milliseconds(300))
        try w.rename("\(image.relativeMountPath)/old.txt", "\(image.relativeMountPath)/new.txt")
        do {
            try await w.waitUntil("renamed", timeout: .seconds(5)) { m.rowNames == ["new.txt"] }
        } catch {
            // Some systems deliver no FSEvents for exFAT images; F5 is the documented fallback.
            m.refresh()
            try await w.waitUntil("renamed after refresh") { m.rowNames == ["new.txt"] }
        }
        XCTAssertEqual(m.row(of: .name("new.txt")), 0)
        XCTAssertFalse(log.changeSets.contains(.reset))
    }
}
