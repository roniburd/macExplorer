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
        let log = FolderEventLog(m)
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

    /// FSEvents (NoDefer) delivers a burst as many small deliveries; each patch re-sorts and diffs the whole
    /// folder, so item events that arrive while a watcher patch is in flight coalesce into one follow-up patch
    /// (§4.4 FSEvent → UI updated).
    func testItemEventsDuringAPatchCoalesceIntoOneFollowUpPatch() async throws {
        let w = try await FolderTestWorld.make(self)
        try w.dir("co")
        try w.file("co/a")
        let m = try await w.open("co")
        let gate = HoldGate()
        defer { gate.open() }
        var calls: [[String]] = []
        m.itemSource = { names, _, generation in
            calls.append(names)
            if calls.count == 1 { await gate.wait() }
            return ItemReadResult(batch: TestBatch.files(generation, names, firstID: UInt64(100 + calls.count * 10)), missing: [], errors: [:])
        }
        try watcher(w).send(.items(["b"]))
        try await w.waitUntil("first patch in flight") { gate.waiting == 1 }
        for name in ["c", "d", "c", "e"] { try watcher(w).send(.items([name])) }
        await w.settle()
        XCTAssertEqual(calls, [["b"]], "nothing else is read while the first patch is in flight")
        gate.open()
        try await w.waitUntil("all applied") { m.rowNames == ["a", "b", "c", "d", "e"] }
        await w.settle()
        XCTAssertEqual(calls, [["b"], ["c", "d", "e"]], "one follow-up patch for the coalesced names")
    }

    /// CI flake root cause (inline rename Tab/⇧Tab): the watcher can split a rename into its two names and reads the
    /// second only after the first applied, so it issues that read after a `reconcile` read and supersedes it.
    /// "The read issued last wins" does not hold for `reconcile` then: its callback must wait for that watcher read
    /// too, or it runs on a listing that does not show the rename yet. Every read is held on a gate.
    func testReconcileWaitsForAWatcherReadIssuedAfterIt() async throws {
        let w = try await FolderTestWorld.make(self)
        try w.dir("rc")
        for name in ["a.txt", "b.txt", "c.txt"] { try w.file("rc/\(name)") }
        let m = try await w.open("rc")
        let disk: Set<String> = ["a1.txt", "b.txt", "c.txt"]   // what the item reads see: a.txt was renamed to a1.txt
        let gates = [HoldGate(), HoldGate(), HoldGate()]
        defer { for gate in gates { gate.open() } }
        var calls: [[String]] = []
        m.itemSource = { names, _, generation in
            calls.append(names)
            let call = calls.count
            if call <= gates.count { await gates[call - 1].wait() }
            return ItemReadResult(batch: TestBatch.files(generation, names.filter(disk.contains), firstID: UInt64(100 * call)),
                                  missing: names.filter { !disk.contains($0) }, errors: [:])
        }
        try watcher(w).send(.items(["a.txt"]))
        try await w.waitUntil("watcher read in flight") { gates[0].waiting == 1 }
        try watcher(w).send(.items(["a1.txt"]))                // coalesced behind the watcher read in flight
        var reconciled: [String]?
        m.reconcile(LocalChange(directory: w.url("rc"), renamed: [.init(from: "a.txt", to: "a1.txt")])) {
            reconciled = m.rowNames
        }
        try await w.waitUntil("reconcile read in flight") { gates[1].waiting == 1 }
        gates[0].open()
        try await w.waitUntil("watcher follow-up read in flight") { gates[2].waiting == 1 }
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls.last.map(Set.init), ["a1.txt", "a.txt"], "the follow-up, issued after reconcile, covers both sides")
        gates[1].open()
        await w.settle()
        XCTAssertNil(reconciled, "the read issued after reconcile is still in flight: the listing is not final yet")
        XCTAssertEqual(m.rowNames, ["a.txt", "b.txt", "c.txt"], "the superseded reads applied nothing")
        gates[2].open()
        try await w.waitUntil("reconciled") { reconciled != nil }
        XCTAssertEqual(reconciled, ["a1.txt", "b.txt", "c.txt"], "the callback sees the listing agree with the disk")
    }

    /// CI flake root cause (inline rename follows its item): a watcher read of only the old name, issued after a
    /// rename post's read, answers for that name first, so the row was deleted while the new name was not listed
    /// yet, and the item lost its identity (an open rename field closed). A read covering one side of a rename
    /// whose read is not applied yet now covers both sides and carries the identity (here: the selection) in one patch.
    func testAWatcherReadOfOneSideOfAPendingRenameReadsBothSides() async throws {
        let w = try await FolderTestWorld.make(self)
        try w.dir("rs")
        for name in ["m.txt", "x.txt"] { try w.file("rs/\(name)") }
        let m = try await w.open("rs")
        let row = try XCTUnwrap(m.row(named: "m.txt"))
        m.select(.set(IndexSet(integer: row), cursor: row))
        let disk: Set<String> = ["n.txt", "x.txt"]   // m.txt was renamed to n.txt
        let gate = HoldGate()
        defer { gate.open() }
        var calls: [[String]] = []
        m.itemSource = { names, _, generation in
            calls.append(names)
            if calls.count == 1 { await gate.wait() }   // the rename post's read answers last
            return ItemReadResult(batch: TestBatch.files(generation, names.filter(disk.contains), firstID: UInt64(100 * calls.count)),
                                  missing: names.filter { !disk.contains($0) }, errors: [:])
        }
        m.applyLocalChange(LocalChange(directory: w.url("rs"), renamed: [.init(from: "m.txt", to: "n.txt")]))
        try await w.waitUntil("rename read in flight") { gate.waiting == 1 }
        try watcher(w).send(.items(["m.txt"]))
        try await w.waitUntil("watcher read applied") { m.rowNames != ["m.txt", "x.txt"] }
        XCTAssertEqual(calls.last.map(Set.init), ["m.txt", "n.txt"], "the watcher read covers both sides of the rename")
        XCTAssertEqual(m.rowNames, ["n.txt", "x.txt"], "never the old name gone and the new one not yet listed")
        XCTAssertEqual(m.selection.rows, IndexSet(integer: 0), "the selection followed the item across the rename")
        gate.open()
        await w.settle()
        XCTAssertEqual(m.rowNames, ["n.txt", "x.txt"])
        XCTAssertEqual(m.selection.rows, IndexSet(integer: 0))
    }

    /// A change that names nothing has nothing to wait for; one for another directory is never this model's.
    func testReconcileWithNothingToReadRunsAtOnce() async throws {
        let w = try await FolderTestWorld.make(self)
        try w.dir("rn")
        let m = try await w.open("rn")
        var ran = false
        m.reconcile(LocalChange(directory: w.url("rn"))) { ran = true }
        XCTAssertTrue(ran, "no names to settle")
        var other = false
        m.reconcile(LocalChange(directory: w.url("elsewhere"), added: ["x"])) { other = true }
        await w.settle()
        XCTAssertFalse(other, "a change for another directory is not this model's to reconcile")
    }

    /// Coalesced names past the incremental limit become one full re-read instead of a giant patch.
    func testCoalescedItemsPastTheLimitBecomeOneReread() async throws {
        let w = try await FolderTestWorld.make(self)
        try w.dir("cl")
        try w.file("cl/a")
        let m = try await w.open("cl")
        let gate = HoldGate()
        defer { gate.open() }
        var calls = 0
        m.itemSource = { names, _, generation in
            calls += 1
            if calls == 1 { await gate.wait() }
            return ItemReadResult(batch: TestBatch.files(generation, names, firstID: 500), missing: [], errors: [:])
        }
        let reads = ScriptedReads()
        m.readSource = reads.source()
        try watcher(w).send(.items(["b"]))
        try await w.waitUntil("first patch in flight") { gate.waiting == 1 }
        for chunk in 0..<3 { try watcher(w).send(.items((0..<100).map { "n\(chunk)-\($0)" })) }
        await w.settle()
        XCTAssertEqual(reads.reads.count, 0)
        gate.open()
        try await w.waitUntil("one re-read") { reads.reads.count == 1 }
        await w.settle()
        XCTAssertEqual(calls, 1, "no item read for the coalesced names")
        XCTAssertEqual(reads.reads.count, 1)
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
        let log = FolderEventLog(m)
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
        let log = FolderEventLog(m)
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
        let log = FolderEventLog(m)
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
        let log = FolderEventLog(m)
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
