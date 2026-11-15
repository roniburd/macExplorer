import XCTest
import Darwin
@testable import Core
import MacxFS

final class JournalTests: FileOpsTestCase {
    func testRecordClearFinishPersistAcrossInstances() async throws {
        let job = JobID()
        let j1 = Journal(fileURL: journalURL)
        let partial = url("dst/.a.macx-partial-\(job.short)")
        try await j1.record(.jobStarted(job: job, description: JobDescription(verb: .moving, itemCount: 1, firstItemName: "a", sourceFolderName: "src", destinationFolderName: "dst")))
        try await j1.record(.partial(job: job, url: partial))
        let j2 = Journal(fileURL: journalURL)                     // as after a relaunch
        let reloaded = await j2.entries()
        XCTAssertEqual(reloaded.count, 2)
        try await j2.clear(.partial(job: job, url: partial))
        let afterClear = await Journal(fileURL: journalURL).entries()
        XCTAssertEqual(afterClear.count, 1)
        try await j2.finish(job: job)
        let afterFinish = await Journal(fileURL: journalURL).entries()
        XCTAssertEqual(afterFinish, [])
    }

    func testJournalFileIsAlwaysValidJSON() async throws {
        let j = Journal(fileURL: journalURL)
        for i in 0..<50 { try await j.record(.partial(job: JobID(), url: url("p\(i)"))) }
        let data = try Data(contentsOf: journalURL)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
        XCTAssertFalse(names(url("state")).contains { $0.hasPrefix(".dat") || $0.hasSuffix(".tmp") }, "no temp leftovers")
    }

    func testCorruptJournalIsSetAsideNotDeleted() async throws {
        try file("state/journal.json", "{ not json")
        let j = Journal(fileURL: journalURL)
        let entries = await j.entries()
        XCTAssertEqual(entries, [])
        XCTAssertTrue(names(url("state")).contains { $0.hasPrefix("journal.corrupt-") })
    }

    func testRecoveryRemovesJournaledPartialsOnly() async throws {
        let job = JobID()
        let partialName = PartialName.make(for: "big", job: job)
        try dir("dst/\(partialName)/inner")
        try file("dst/\(partialName)/inner/f", "partial bytes")
        let impostor = try file("dst/not-a-partial", "user data")      // journaled by a bug: must survive
        let j = Journal(fileURL: journalURL)
        try await j.record(.jobStarted(job: job, description: JobDescription(verb: .moving, itemCount: 1, firstItemName: "big", sourceFolderName: nil, destinationFolderName: nil)))
        try await j.record(.partial(job: job, url: url("dst/\(partialName)")))
        try await j.record(.partial(job: job, url: impostor))
        let report = await LaunchRecovery.run(journal: j, lanes: LanePool())
        XCTAssertEqual(report.removedPartials, [url("dst/\(partialName)")])
        XCTAssertFalse(exists(url("dst/\(partialName)")))
        XCTAssertEqual(text(impostor), "user data")
        XCTAssertEqual(report.incompleteJobs.map(\.firstItemName), ["big"])
        let left = await j.entries()
        XCTAssertEqual(left, [])
    }

    private func started(_ job: JobID) -> JournalEntry {
        .jobStarted(job: job, description: JobDescription(verb: .moving, itemCount: 1, firstItemName: "x", sourceFolderName: nil,
                                                          destinationFolderName: nil))
    }

    /// Review B1-4: an entry recovery can't act on (its volume is not mounted) is kept and reported, then acted on at a
    /// later launch; resolved entries and the job's start go.
    func testRecoveryKeepsEntriesItCouldNotActOnForTheNextLaunch() async throws {
        let job = JobID()
        let partial = url("vol/dst/\(PartialName.make(for: "big", job: job))")      // "vol" is not there yet
        let gone = url("dst/\(PartialName.make(for: "small", job: job))")           // folder there, partial gone: resolved
        try dir("dst")
        let j = Journal(fileURL: journalURL)
        try await j.record(started(job))
        try await j.record(.partial(job: job, url: partial))
        try await j.record(.partial(job: job, url: gone))
        let first = await LaunchRecovery.run(journal: j, lanes: LanePool())
        XCTAssertEqual(first.pendingRecoveries, [partial])
        XCTAssertEqual(first.incompleteJobs.count, 1)
        XCTAssertFalse(first.isEmpty)
        let kept = await Journal(fileURL: journalURL).entries()
        XCTAssertEqual(kept, [.partial(job: job, url: partial)])

        try dir("vol/dst/\(partial.lastPathComponent)")                             // the volume is back
        try file("vol/dst/\(partial.lastPathComponent)/f", "partial bytes")
        let second = await LaunchRecovery.run(journal: Journal(fileURL: journalURL), lanes: LanePool())
        XCTAssertEqual(second.removedPartials, [partial])
        XCTAssertEqual(second.pendingRecoveries, [])
        XCTAssertEqual(second.incompleteJobs, [], "reported once")
        XCTAssertFalse(exists(partial))
        let left = await Journal(fileURL: journalURL).entries()
        XCTAssertEqual(left, [])
    }

    func testRecoveryKeepsATrashedDestinationWhoseRestoreFailed() async throws {
        let job = JobID()
        let trashed = try file(".trash/b1/a", "old")
        try dir("d")
        let original = url("d/a")
        let j = Journal(fileURL: journalURL)
        try await j.record(started(job))
        try await j.record(.trashedDestination(job: job, original: original, trashURL: trashed))
        XCTAssertEqual(chmod(url("d").path, 0o500), 0)                              // the rename back fails
        let first = await LaunchRecovery.run(journal: j, lanes: LanePool())
        XCTAssertEqual(first.restoredDestinations, [])
        XCTAssertEqual(first.pendingRecoveries, [original])
        XCTAssertEqual(chmod(url("d").path, 0o755), 0)
        let second = await LaunchRecovery.run(journal: Journal(fileURL: journalURL), lanes: LanePool())
        XCTAssertEqual(second.restoredDestinations, [original])
        XCTAssertEqual(text(original), "old")
        let left = await Journal(fileURL: journalURL).entries()
        XCTAssertEqual(left, [])
    }

    /// Kept entries are dropped after `maxAttempts` launches (a volume that never comes back).
    func testRecoveryDropsKeptEntriesAfterTheLastAttempt() async throws {
        let job = JobID()
        let partial = url("vol/\(PartialName.make(for: "big", job: job))")
        try await Journal(fileURL: journalURL).record(.partial(job: job, url: partial))
        for launch in 1...LaunchRecovery.maxAttempts {
            let report = await LaunchRecovery.run(journal: Journal(fileURL: journalURL), lanes: LanePool())
            XCTAssertEqual(report.pendingRecoveries, launch < LaunchRecovery.maxAttempts ? [partial] : [], "launch \(launch)")
        }
        let left = await Journal(fileURL: journalURL).entries()
        XCTAssertEqual(left, [])
    }

    /// A destination set aside on a volume without a Trash, after the new item landed: the Replace completed.
    func testRecoveryDeletesASetAsideDestinationOnceTheNewItemIsInPlace() async throws {
        let job = JobID()
        let aside = try file("d/\(PartialName.make(for: "a.replaced", job: job))", "old")
        let original = try file("d/a", "new")
        let j = Journal(fileURL: journalURL)
        try await j.record(.trashedDestination(job: job, original: original, trashURL: aside))
        let report = await LaunchRecovery.run(journal: j, lanes: LanePool())
        XCTAssertEqual(report.removedPartials, [aside])
        XCTAssertEqual(names(url("d")), ["a"])
        XCTAssertEqual(text(original), "new")
    }

    func testRecoveryRemovesLockedPartialTree() async throws {
        let job = JobID()
        let p = PartialName.make(for: "locked", job: job)
        try file("dst/\(p)/f", "x")
        XCTAssertEqual(lchflags(url("dst/\(p)/f").path, UInt32(UF_IMMUTABLE)), 0)
        let j = Journal(fileURL: journalURL)
        try await j.record(.partial(job: job, url: url("dst/\(p)")))
        let report = await LaunchRecovery.run(journal: j, lanes: LanePool())
        XCTAssertEqual(report.removedPartials.count, 1)
        XCTAssertFalse(exists(url("dst/\(p)")))
    }

    func testRecoveryRestoresTrashedDestinationOnlyWhenOriginalIsFree() async throws {
        let job = JobID()
        let trashed = try file(".trash/b1/a.txt", "old")
        let trashed2 = try file(".trash/b2/c.txt", "old c")
        try file("dst/c.txt", "new c")                                  // replacement landed
        let j = Journal(fileURL: journalURL)
        try await j.record(.trashedDestination(job: job, original: url("dst/a.txt"), trashURL: trashed))
        try await j.record(.trashedDestination(job: job, original: url("dst/c.txt"), trashURL: trashed2))
        let report = await LaunchRecovery.run(journal: j, lanes: LanePool())
        XCTAssertEqual(report.restoredDestinations, [url("dst/a.txt")])
        XCTAssertEqual(text(url("dst/a.txt")), "old")
        XCTAssertEqual(text(url("dst/c.txt")), "new c")
        XCTAssertEqual(text(trashed2), "old c")                          // stays in the trash
    }

    func testRecoveryRestoresInterruptedTwoStepRename() async throws {
        let job = JobID()
        let temp = try file("d/.tmp.macx-rename-\(job.short)", "content")
        let j = Journal(fileURL: journalURL)
        try await j.record(.twoStepRename(job: job, temporary: temp, original: url("d/a.txt"), target: url("d/A.txt")))
        let report = await LaunchRecovery.run(journal: j, lanes: LanePool())
        XCTAssertEqual(report.restoredRenames, [url("d/a.txt")])
        XCTAssertEqual(text(url("d/a.txt")), "content")
        XCTAssertFalse(exists(temp))
    }

    func testEmptyJournalYieldsEmptyReport() async {
        let report = await LaunchRecovery.run(journal: Journal(fileURL: journalURL), lanes: LanePool())
        XCTAssertTrue(report.isEmpty)
    }

    func testSandboxTrashMovesIntoBucketAndReturnsURL() async throws {
        let a = try file("a.txt", "A")
        let trash = SandboxTrash(directory: trashDir)
        let result = try await LanePool().perform(on: .unknown, .fileOp) { _ in try trash.trash(a) }
        XCTAssertFalse(exists(a))
        XCTAssertEqual(result.lastPathComponent, "a.txt")
        XCTAssertTrue(result.path.hasPrefix(trashDir.path + "/"))
        XCTAssertEqual(text(result), "A")
    }

    func testSandboxTrashRefusingPrefixThrowsNoTrash() async throws {
        let a = try file("nt/a.txt")
        let trash = SandboxTrash(directory: trashDir, refusingPathsUnder: [url("nt")])
        do {
            _ = try await LanePool().perform(on: .unknown, .fileOp) { _ in try trash.trash(a) }
            XCTFail("expected noTrash")
        } catch let e as FileOpError {
            XCTAssertEqual(e.kind, .noTrash)
        }
        XCTAssertTrue(exists(a))
    }

    /// SystemTrash only ever runs on a test-created image (its Trash is inside the image).
    func testSystemTrashOnDiskImage() async throws {
        let mnt = try image(.hfsPlus, sizeMB: 32)
        let f = mnt.appending(path: "t.txt")
        try Data("t".utf8).write(to: f)
        let result = try await LanePool().perform(on: .unknown, .fileOp) { _ in try SystemTrash().trash(f) }
        XCTAssertTrue(result.path.hasPrefix(mnt.path + "/"), "trash of an image item stays on the image: \(result.path)")
        XCTAssertFalse(exists(f))
    }
}
