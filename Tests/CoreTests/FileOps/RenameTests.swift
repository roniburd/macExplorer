import XCTest
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
