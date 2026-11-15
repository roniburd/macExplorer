import XCTest
import Synchronization
import Darwin
@testable import Core
import MacxFS

final class RenameTests: FileOpsTestCase {
    // MARK: NameGenerator (pure)

    func testKeepBothNames() {
        var taken: Set<String> = ["x.txt"]
        XCTAssertEqual(NameGenerator.keepBoth("x.txt", isDirectory: false) { taken.contains($0) }, "x 2.txt")
        taken.insert("x 2.txt")
        XCTAssertEqual(NameGenerator.keepBoth("x.txt", isDirectory: false) { taken.contains($0) }, "x 3.txt")
        XCTAssertEqual(NameGenerator.keepBoth("x 2.txt", isDirectory: false) { taken.contains($0) }, "x 3.txt")
        XCTAssertEqual(NameGenerator.keepBoth("photos.album", isDirectory: true) { _ in false }, "photos.album 2")
        XCTAssertEqual(NameGenerator.keepBoth(".env", isDirectory: false) { _ in false }, ".env 2")
        XCTAssertEqual(NameGenerator.keepBoth("Makefile", isDirectory: false) { _ in false }, "Makefile 2")
        let long = String(repeating: "a", count: 251) + ".txt"
        let kept = NameGenerator.keepBoth(long, isDirectory: false) { _ in false }
        XCTAssertLessThanOrEqual(kept.utf8.count, 255)
        XCTAssertTrue(kept.hasSuffix(" 2.txt"))
    }

    /// Review B1-7: only a plausible earlier counter (2…99, no leading zero, and the unsuffixed sibling exists) is
    /// bumped; other numbers are name.
    func testKeepBothKeepsNumbersThatAreNotACounter() {
        let none: (String) -> Bool = { _ in false }
        XCTAssertEqual(NameGenerator.keepBoth("IMG 0001.jpg", isDirectory: false, taken: none), "IMG 0001 2.jpg")
        XCTAssertEqual(NameGenerator.keepBoth("Report 2024.pdf", isDirectory: false, taken: none), "Report 2024 2.pdf")
        XCTAssertEqual(NameGenerator.keepBoth("Chapter 1.pdf", isDirectory: false, taken: none), "Chapter 1 2.pdf")
        XCTAssertEqual(NameGenerator.keepBoth("Take 05.wav", isDirectory: false, taken: none), "Take 05 2.wav")
        XCTAssertEqual(NameGenerator.keepBoth("Scan 100.png", isDirectory: false, taken: none), "Scan 100 2.png")
        XCTAssertEqual(NameGenerator.keepBoth("Folder 9", isDirectory: true, taken: none), "Folder 9 2")
        XCTAssertEqual(NameGenerator.keepBoth("Folder 9", isDirectory: true) { $0 == "Folder" }, "Folder 10")
        XCTAssertEqual(NameGenerator.keepBoth("x 99.txt", isDirectory: false) { $0 == "x.txt" }, "x 100.txt")
        // An album folder: "Track 10" is a real track, not our counter, even with "Track 11" taken.
        let album: Set<String> = ["Track 10.mp3", "Track 11.mp3", "Track 12.mp3"]
        XCTAssertEqual(NameGenerator.keepBoth("Track 10.mp3", isDirectory: false) { album.contains($0) }, "Track 10 2.mp3")
        XCTAssertEqual(NameGenerator.keepBoth("Episode 5.mkv", isDirectory: false, taken: none), "Episode 5 2.mkv")
        let taken: Set<String> = ["IMG 0001 2.jpg"]
        XCTAssertEqual(NameGenerator.keepBoth("IMG 0001.jpg", isDirectory: false) { taken.contains($0) }, "IMG 0001 3.jpg")
    }

    func testCopyNames() {
        var taken: Set<String> = []
        XCTAssertEqual(NameGenerator.copyName("a.txt", isDirectory: false) { taken.contains($0) }, "a copy.txt")
        taken = ["a copy.txt"]
        XCTAssertEqual(NameGenerator.copyName("a.txt", isDirectory: false) { taken.contains($0) }, "a copy 2.txt")
        XCTAssertEqual(NameGenerator.copyName("dir", isDirectory: true) { _ in false }, "dir copy")
    }

    func testNewItemNames() {
        XCTAssertEqual(NameGenerator.newItemName(.folder) { _ in false }, "New Folder")
        XCTAssertEqual(NameGenerator.newItemName(.folder) { $0 == "New Folder" }, "New Folder 2")
        XCTAssertEqual(NameGenerator.newItemName(.textFile) { _ in false }, "Untitled.txt")
        XCTAssertEqual(NameGenerator.newItemName(.textFile) { $0 == "Untitled.txt" }, "Untitled 2.txt")
        XCTAssertEqual(NameGenerator.newItemName(.emptyFile) { _ in false }, "Untitled")
    }

    func testIsSameItemRename() {
        XCTAssertTrue(RenamePrimitive.isSameItemRename("a.txt", "A.txt", caseSensitive: false))
        XCTAssertFalse(RenamePrimitive.isSameItemRename("a.txt", "A.txt", caseSensitive: true))
        XCTAssertTrue(RenamePrimitive.isSameItemRename("caf\u{E9}", "cafe\u{301}", caseSensitive: true))
        XCTAssertFalse(RenamePrimitive.isSameItemRename("a.txt", "a.txt", caseSensitive: false))
        XCTAssertFalse(RenamePrimitive.isSameItemRename("a.txt", "b.txt", caseSensitive: false))
    }

    // MARK: primitive

    func testRenamePrimitiveExclusiveAndFallback() async throws {
        let a = try file("a", "A"), b = try file("b", "B")
        let lanes = LanePool()
        for excl in [true, false] {
            let r = try await lanes.perform(on: .unknown, .fileOp) { _ in RenamePrimitive.rename(a.path, b.path, renameExcl: excl) }
            XCTAssertEqual(r, .exists, "excl=\(excl)")
            XCTAssertEqual(text(b), "B")
        }
        let c = url("c")
        let ok = try await lanes.perform(on: .unknown, .fileOp) { _ in RenamePrimitive.rename(a.path, c.path, renameExcl: false) }
        XCTAssertEqual(ok, .renamed)
        XCTAssertEqual(text(c), "A")
    }

    // MARK: jobs

    func testRenameJobRenamesRecordsAndPostsLocalChange() async throws {
        let a = try file("d/a.txt", "A")
        let inode = lst(a).st_ino
        let (queue, _) = makeQueue()
        let outcome = try await run(.rename(a, to: "b.txt"), on: queue)
        let b = url("d/b.txt")
        XCTAssertEqual(text(b), "A")
        XCTAssertFalse(exists(a))
        XCTAssertEqual(lst(b).st_ino, inode)
        guard case .renamed(let from, let to, let id)? = outcome.record.actions.first else { return XCTFail("\(outcome.record)") }
        XCTAssertEqual(from, a); XCTAssertEqual(to, b); XCTAssertEqual(id.inode, inode)
        XCTAssertEqual(outcome.localChanges.first?.renamed, [LocalChange.Rename(from: "a.txt", to: "b.txt")])
        XCTAssertEqual(outcome.localChanges.first?.select, ["b.txt"])
    }

    func testRenameOntoExistingNameNeverOverwrites() async throws {
        let a = try file("a.txt", "A"); try file("b.txt", "B")
        let scripted = ScriptedInteraction(errors: [.skip])
        let (queue, _) = makeQueue(interaction: scripted)
        let outcome = try await run(.rename(a, to: "b.txt"), on: queue)
        XCTAssertEqual(text(url("b.txt")), "B")
        XCTAssertEqual(text(a), "A")
        XCTAssertEqual(scripted.askedErrors().first?.kind, .other(code: EEXIST, message: String(cString: strerror(EEXIST))))
        XCTAssertEqual(outcome.record.actions, [])
    }

    func testCaseOnlyRenameOnSandboxVolume() async throws {
        let a = try file("d/a.txt", "A")
        let (queue, journal) = makeQueue()
        _ = try await run(.rename(a, to: "A.txt"), on: queue)
        XCTAssertEqual(names(url("d")), ["A.txt"])
        let entries = await journal.entries()
        XCTAssertEqual(entries, [])
    }

    func testNormalizationOnlyRenameStoresNewBytes() async throws {
        let nfc = "caf\u{E9}.txt", nfd = "cafe\u{301}.txt"
        let d = try dir("d")
        // open(2) with the NFC bytes themselves (Foundation's file APIs would store a decomposed name).
        let fd = open(d.path + "/" + nfc, O_CREAT | O_EXCL | O_WRONLY, 0o644)   // Swift passes the String's own UTF-8
        XCTAssertGreaterThanOrEqual(fd, 0); close(fd)
        let dirPath = d.path
        let lanes = LanePool()
        let before = try await lanes.perform(on: .unknown, .fileOp) { _ in
            (RenamePrimitive.directory(dirPath, containsExactly: nfc), RenamePrimitive.directory(dirPath, containsExactly: nfd))
        }
        XCTAssertTrue(before.0, "fixture stored with NFC bytes"); XCTAssertFalse(before.1)
        let (queue, _) = makeQueue()
        _ = try await run(.rename(d.appending(path: nfc), to: nfd), on: queue)
        let after = try await lanes.perform(on: .unknown, .fileOp) { _ in
            (RenamePrimitive.directory(dirPath, containsExactly: nfc), RenamePrimitive.directory(dirPath, containsExactly: nfd))
        }
        XCTAssertFalse(after.0); XCTAssertTrue(after.1, "the new NFD bytes are on disk")
    }

    func testCaseOnlyRenameOnExFATImage() async throws {
        let mnt = try image(.exfat, sizeMB: 32)
        let a = mnt.appending(path: "a.txt")
        try Data("A".utf8).write(to: a)
        let (queue, journal) = makeQueue()
        let outcome = try await run(.rename(a, to: "A.txt"), on: queue)
        let mntPath = mnt.path
        let exact = try await LanePool().perform(on: .unknown, .fileOp) { _ in RenamePrimitive.directory(mntPath, containsExactly: "A.txt") }
        XCTAssertTrue(exact, "exFAT listing: \(names(mnt))")
        XCTAssertEqual(text(mnt.appending(path: "A.txt")), "A")
        XCTAssertEqual(outcome.skipped, [])
        let entries = await journal.entries()
        XCTAssertEqual(entries, [], "two-step journal entry cleared")
    }

    func testCaseOnlyRenameNeverReplacesADistinctFileWhenCaseLookupIsWrong() async throws {
        let mnt = try image(.apfsCaseSensitive, sizeMB: 32)
        let a = mnt.appending(path: "a"), upper = mnt.appending(path: "A")
        try Data("lower".utf8).write(to: a)
        try Data("upper".utf8).write(to: upper)
        var tuning = FileOpTuning(); tuning.forceCaseInsensitive = true
        let scripted = ScriptedInteraction(errors: [.skip])
        let (queue, _) = makeQueue(interaction: scripted, tuning: tuning)
        let outcome = try await run(.rename(a, to: "A"), on: queue)
        XCTAssertEqual(text(a), "lower")
        XCTAssertEqual(text(upper), "upper", "the other file is never overwritten")
        XCTAssertEqual(scripted.askedErrors().first?.kind, .other(code: EEXIST, message: String(cString: strerror(EEXIST))))
        XCTAssertEqual(outcome.record.actions, [])
    }

    func testTwoStepRenameNeverReplacesAnOccupiedTarget() async throws {
        let mnt = try image(.apfsCaseSensitive, sizeMB: 32)
        let a = mnt.appending(path: "a"), upper = mnt.appending(path: "A")
        try Data("lower".utf8).write(to: a)
        try Data("upper".utf8).write(to: upper)
        let ctx = JobContext(id: JobID(), request: request(.rename(a, to: "A")), lanes: LanePool(),
                             trash: SandboxTrash(directory: trashDir), journal: Journal(fileURL: journalURL),
                             interaction: ScriptedInteraction(errors: [.skip]), tuning: FileOpTuning())
        let r = await CreateOps.twoStepRename(ctx, from: a, to: upper)
        XCTAssertEqual(r, .skipped)
        XCTAssertEqual(text(a), "lower", "put back")
        XCTAssertEqual(text(upper), "upper")
        XCTAssertEqual(names(mnt).filter { $0.contains("macx-rename") }, [])
    }

    func testTwoStepRenameLandsAndClearsJournal() async throws {
        let a = try file("d/a.txt", "A")
        let journal = Journal(fileURL: journalURL)
        let ctx = JobContext(id: JobID(), request: request(.rename(a, to: "A.txt")), lanes: LanePool(),
                             trash: SandboxTrash(directory: trashDir), journal: journal,
                             interaction: ScriptedInteraction(), tuning: FileOpTuning())
        let r = await CreateOps.twoStepRename(ctx, from: a, to: url("d/A.txt"))
        XCTAssertEqual(r, .done)
        XCTAssertEqual(names(url("d")), ["A.txt"])
        let entries = await journal.entries()
        XCTAssertEqual(entries.filter { if case .twoStepRename = $0 { true } else { false } }, [])
    }

    /// Review B1-5: the second step failed and so did the rename back (something now holds the original name). The
    /// journal entry outlives the job, and the next launch puts the item back.
    func testTwoStepRenameKeepsItsJournalEntryWhenTheRollbackFails() async throws {
        let a = try file("d/a.txt", "A"); try file("d/b.txt", "B")                 // the target is taken: step two fails
        let aPath = a.path
        let tuning = FileOpTuning(faultHook: { point, _ in
            if point == .betweenRenameSteps { _ = FileManager.default.createFile(atPath: aPath, contents: Data("blocker".utf8)) }
        })
        let journal = Journal(fileURL: journalURL)
        let scripted = ScriptedInteraction(errors: [.skip])
        let ctx = JobContext(id: JobID(), request: request(.rename(a, to: "b.txt")), lanes: LanePool(),
                             trash: SandboxTrash(directory: trashDir), journal: journal, interaction: scripted, tuning: tuning)
        let r = await CreateOps.twoStepRename(ctx, from: a, to: url("d/b.txt"))
        XCTAssertEqual(r, .skipped)
        XCTAssertEqual(scripted.askedErrors().count, 1, "the failure is surfaced")
        XCTAssertEqual(text(a), "blocker", "the rename back never replaces what appeared at the original name")
        XCTAssertEqual(text(url("d/b.txt")), "B")
        XCTAssertEqual(names(url("d")).filter { $0.contains("macx-rename") }.count, 1, "the item waits at its temporary name")
        try await journal.finish(job: ctx.id, keeping: ctx.keptForRecovery())       // as JobRunner does
        let kept = await journal.entries()
        XCTAssertEqual(kept.filter { if case .twoStepRename = $0 { true } else { false } }.count, 1)
        try FileManager.default.removeItem(at: a)                                   // the blocker goes; next launch:
        let report = await LaunchRecovery.run(journal: Journal(fileURL: journalURL), lanes: LanePool())
        XCTAssertEqual(report.restoredRenames, [a])
        XCTAssertEqual(text(a), "A")
        let left = await Journal(fileURL: journalURL).entries()
        XCTAssertEqual(left, [])
    }

    /// Review B1 follow-up: the same failure in a queued job: the job's finish (JobRunner.finish, shared by every job)
    /// keeps the entry, not test code, and nothing else of the job is left in the journal. (APFS renames a case-only
    /// change in place, so the two-step path is driven through the body override.)
    func testTwoStepRenameInAQueuedJobKeepsItsJournalEntryWhenTheRollbackFails() async throws {
        let a = try file("d/a.txt", "A"); let b = try file("d/b.txt", "B")          // the target is taken: step two fails
        let aPath = a.path
        var tuning = FileOpTuning(faultHook: { point, _ in
            if point == .betweenRenameSteps { _ = FileManager.default.createFile(atPath: aPath, contents: Data("blocker".utf8)) }
        })
        tuning.bodyOverride = { ctx in
            _ = await CreateOps.twoStepRename(ctx, from: a, to: b)
        }
        let scripted = ScriptedInteraction(errors: [.skip])
        let (queue, journal) = makeQueue(interaction: scripted, tuning: tuning)
        _ = try await run(.rename(a, to: "b.txt"), on: queue)
        XCTAssertEqual(scripted.askedErrors().count, 1)
        XCTAssertEqual(names(url("d")).filter { $0.contains("macx-rename") }.count, 1)
        let kept = await journal.entries()
        guard kept.count == 1, case .twoStepRename(_, _, let original, _) = kept[0] else { return XCTFail("\(kept)") }
        XCTAssertEqual(original, a)
    }

    /// Removes `blocker` when asked about the error, then answers Retry.
    private final class BlockerRemovingInteraction: FileOpInteraction, @unchecked Sendable {
        let blocker: String
        init(blocker: String) { self.blocker = blocker }
        func resolveConflict(_ conflict: ConflictInfo, job: JobSnapshot) async -> ConflictResolution { .one(.skip) }
        let asked = Mutex(0)
        func resolveError(_ error: FileOpError, job: JobSnapshot) async -> ErrorResolution {
            asked.withLock { $0 += 1 }
            _ = unlink(blocker)
            return .retry
        }
        func confirmInsufficientSpace(_ shortfall: SpaceShortfall, job: JobSnapshot) async -> Bool { false }
        func confirmPermanentDeleteWithoutTrash(_ urls: [URL], job: JobSnapshot) async -> Bool { false }
    }

    /// Review B1 follow-up: Retry after a failed rename back resumes from the temporary name and lands at the target;
    /// no temporary file and no journal entry are left.
    func testTwoStepRenameRetryResumesFromTheTemporaryName() async throws {
        let a = try file("d/a.txt", "A")
        let aPath = a.path, target = url("d/A.txt")
        var tuning = FileOpTuning(faultHook: { point, _ in
            // Holds both "a.txt" and (case-insensitively) "A.txt": step two and the rename back both fail.
            if point == .betweenRenameSteps { _ = FileManager.default.createFile(atPath: aPath, contents: Data("blocker".utf8)) }
        })
        let result = Mutex<StepResult?>(nil)
        tuning.bodyOverride = { ctx in
            let r = await CreateOps.twoStepRename(ctx, from: a, to: target)
            result.withLock { $0 = r }
        }
        let interaction = BlockerRemovingInteraction(blocker: aPath)
        let journal = Journal(fileURL: journalURL)
        let queue = FileOpQueue(lanes: LanePool(), trash: SandboxTrash(directory: trashDir), journal: journal,
                                interaction: interaction, tuning: tuning)
        _ = try await run(.rename(a, to: "A.txt"), on: queue)
        XCTAssertEqual(result.withLock { $0 }, .done)
        XCTAssertEqual(interaction.asked.withLock { $0 }, 1, "the stranded item was surfaced once, then retried")
        XCTAssertEqual(names(url("d")), ["A.txt"], "landed at the target, no temporary name left")
        XCTAssertEqual(text(target), "A")
        let entries = await journal.entries()
        XCTAssertEqual(entries, [])
    }

    /// Answers the first error by making the journal writable again, then gives `answer`.
    private final class JournalFixingInteraction: FileOpInteraction, @unchecked Sendable {
        let statePath: String
        let answer: ErrorResolution
        init(statePath: String, answer: ErrorResolution) { self.statePath = statePath; self.answer = answer }
        func resolveConflict(_ conflict: ConflictInfo, job: JobSnapshot) async -> ConflictResolution { .one(.skip) }
        func resolveError(_ error: FileOpError, job: JobSnapshot) async -> ErrorResolution {
            _ = chmod(statePath, 0o755)
            return answer
        }
        func confirmInsufficientSpace(_ shortfall: SpaceShortfall, job: JobSnapshot) async -> Bool { false }
        func confirmPermanentDeleteWithoutTrash(_ urls: [URL], job: JobSnapshot) async -> Bool { false }
    }

    /// Review B1-5: a failed journal write honors Retry and Cancel (it always skipped).
    func testTwoStepRenameHonorsRetryAndCancelWhenTheJournalCannotBeWritten() async throws {
        for answer in [ErrorResolution.retry, .cancel] {
            let a = try file("d\(answer)/a.txt", "A")
            XCTAssertEqual(chmod(url("state").path, 0o500), 0)                       // the journal write fails
            let ctx = JobContext(id: JobID(), request: request(.rename(a, to: "A.txt")), lanes: LanePool(),
                                 trash: SandboxTrash(directory: trashDir), journal: Journal(fileURL: journalURL),
                                 interaction: JournalFixingInteraction(statePath: url("state").path, answer: answer),
                                 tuning: FileOpTuning())
            let r = await CreateOps.twoStepRename(ctx, from: a, to: url("d\(answer)/A.txt"))
            if answer == .retry {
                XCTAssertEqual(r, .done)
                XCTAssertEqual(names(url("d\(answer)")), ["A.txt"])
            } else {
                XCTAssertEqual(r, .cancelled)
                XCTAssertTrue(ctx.control.isCancelled)
                XCTAssertEqual(names(url("d\(answer)")), ["a.txt"])
            }
        }
    }

    func testRenameRejectsSlashEmptyAndTooLong() async throws {
        let a = try file("a.txt")
        let scripted = ScriptedInteraction()
        let (queue, _) = makeQueue(interaction: scripted)
        for bad in ["x/y", "", String(repeating: "n", count: 256)] {
            let outcome = try await run(.rename(a, to: bad), on: queue)
            XCTAssertEqual(outcome.record.actions, [], bad)
        }
        XCTAssertTrue(exists(a))
        XCTAssertEqual(scripted.askedErrors().last?.kind, .nameTooLong)
    }

    func testRenameLockedItemOffersUnlockAndContinue() async throws {
        let a = try file("a.txt", "A")
        XCTAssertEqual(lchflags(a.path, UInt32(UF_IMMUTABLE)), 0)
        let scripted = ScriptedInteraction(errors: [.unlockAndContinue])
        let (queue, _) = makeQueue(interaction: scripted)
        _ = try await run(.rename(a, to: "b.txt"), on: queue)
        XCTAssertEqual(scripted.askedErrors().first?.kind, .locked)
        XCTAssertEqual(text(url("b.txt")), "A")
    }

    func testNewItemsGetSequentialNamesAndBeginRename() async throws {
        let d = try dir("d")
        let (queue, _) = makeQueue()
        let o1 = try await run(.newItem(.folder, in: d), on: queue)
        let o2 = try await run(.newItem(.folder, in: d), on: queue)
        let o3 = try await run(.newItem(.textFile, in: d), on: queue)
        let o4 = try await run(.newItem(.emptyFile, in: d), on: queue)
        XCTAssertEqual(names(d), ["New Folder", "New Folder 2", "Untitled", "Untitled.txt"])
        XCTAssertEqual(o1.localChanges.first?.beginRename, "New Folder")
        XCTAssertEqual(o2.created.map(\.lastPathComponent), ["New Folder 2"])
        XCTAssertEqual(o3.localChanges.first?.added, ["Untitled.txt"])
        guard case .created(let u, _)? = o4.record.actions.first else { return XCTFail() }
        XCTAssertEqual(u.lastPathComponent, "Untitled")
        XCTAssertEqual(lst(url("d/Untitled.txt")).st_size, 0)
    }
}
