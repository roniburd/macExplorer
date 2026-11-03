import XCTest
import Darwin
@testable import Core
import MacxFS

final class MoveTests: FileOpsTestCase {
    private func partials(_ dir: URL) -> [String] { names(dir).filter { $0.contains(PartialName.marker) } }

    func testSameVolumeMoveKeepsInodeAndRecords() async throws {
        let a = try file("src/a.txt", "A")
        let inode = lst(a).st_ino
        let d = try dir("d")
        let (queue, _) = makeQueue()
        let o = try await run(.move(sources: [a], destination: d), on: queue)
        XCTAssertFalse(exists(a))
        XCTAssertEqual(lst(url("d/a.txt")).st_ino, inode)
        guard case .moved(let from, let to, let id)? = o.record.actions.first else { return XCTFail("\(o.record)") }
        XCTAssertEqual(from, a); XCTAssertEqual(to, url("d/a.txt")); XCTAssertEqual(id.inode, inode)
        XCTAssertEqual(Set(o.localChanges.flatMap(\.removed)), ["a.txt"])
        XCTAssertEqual(Set(o.localChanges.flatMap(\.added)), ["a.txt"])
    }

    func testSameVolumeMoveOfFolder() async throws {
        try file("src/T/x"); try file("src/T/y/z")
        let (queue, _) = makeQueue()
        _ = try await run(.move(sources: [url("src/T")], destination: try dir("d")), on: queue)
        XCTAssertEqual(names(url("d/T")), ["x", "y"])
        XCTAssertFalse(exists(url("src/T")))
    }

    func testMoveIntoOwnFolderIsNoOp() async throws {
        let a = try file("d/a.txt")
        let scripted = ScriptedInteraction()
        let (queue, _) = makeQueue(interaction: scripted)
        let o = try await run(.move(sources: [a], destination: url("d")), on: queue)
        XCTAssertEqual(o.record.actions, [])
        XCTAssertEqual(scripted.askedConflicts().count, 0)
        XCTAssertTrue(exists(a))
    }

    func testForcedCrossVolumeMoveCopiesVerifiesAndDeletesSource() async throws {
        try file("src/T/x", "X"); try bigFile("src/T/y/big", bytes: 2 << 20)
        var tuning = FileOpTuning(); tuning.forceCrossVolume = true
        let (queue, journal) = makeQueue(tuning: tuning)
        let d = try dir("d")
        let o = try await run(.move(sources: [url("src/T")], destination: d), on: queue)
        XCTAssertEqual(text(url("d/T/x")), "X")
        XCTAssertEqual(lst(url("d/T/y/big")).st_size, 2 << 20)
        XCTAssertFalse(exists(url("src/T")))
        XCTAssertEqual(partials(d), [])
        guard case .moved(let from, let to, _)? = o.record.actions.last else { return XCTFail("\(o.record)") }
        XCTAssertEqual(from, url("src/T")); XCTAssertEqual(to, url("d/T"))
        let entries = await journal.entries()
        XCTAssertEqual(entries, [])
    }

    func testCrossVolumeMoveToDiskImage() async throws {
        let mnt = try image(.hfsPlus, sizeMB: 32)
        try file("src/T/x", "X"); try file("src/T/sub/y", "Y")
        let (queue, _) = makeQueue()
        let o = try await run(.move(sources: [url("src/T")], destination: mnt), on: queue)
        XCTAssertEqual(text(mnt.appending(path: "T/sub/y")), "Y")
        XCTAssertFalse(exists(url("src/T")))
        XCTAssertEqual(partials(mnt), [])
        XCTAssertEqual(o.skipped, [])
    }

    func testCrossDeviceRenameFallsBackToCopy() async throws {
        let mnt = try image(.hfsPlus, sizeMB: 16)
        let a = try file("a.txt", "A")
        let lanes = LanePool()
        let item = try await lanes.perform(on: .unknown, .fileOp) { lane in
            Planner.plan(sources: [a], destination: nil, mode: .shallow, forceCrossVolume: false, lane: lane).items[0]
        }
        XCTAssertTrue(item.sameVolume, "planned as same-volume, so the rename will hit EXDEV")
        let ctx = JobContext(id: JobID(), request: JobRequest(.move(sources: [a], destination: mnt)), lanes: lanes,
                             trash: SandboxTrash(directory: trashDir), journal: Journal(fileURL: journalURL),
                             interaction: ScriptedInteraction(), tuning: FileOpTuning())
        let r = await MoveJob.moveItem(ctx, item, to: mnt.appending(path: "a.txt"), renameExcl: true)
        XCTAssertEqual(r, .done)
        XCTAssertEqual(text(mnt.appending(path: "a.txt")), "A")
        XCTAssertFalse(exists(a))
    }

    /// Review Focus 3 (mandatory name).
    func testCrossVolumeMoveKeepsSourceWhenItChangesDuringCopy() async throws {
        let src = try bigFile("src/log.txt", bytes: 1 << 20)
        let d = try dir("d")
        let srcPath = src.path
        var tuning = FileOpTuning(faultHook: { point, _ in
            guard point == .afterPartialCopy, let h = FileHandle(forWritingAtPath: srcPath) else { return }
            h.seekToEndOfFile(); h.write(Data("more".utf8)); h.closeFile()
        })
        tuning.forceCrossVolume = true
        let scripted = ScriptedInteraction(errors: [.skip])
        let (queue, journal) = makeQueue(interaction: scripted, tuning: tuning)
        let o = try await run(.move(sources: [src], destination: d), on: queue)
        XCTAssertEqual(scripted.askedErrors().map(\.kind), [.changedDuringMove])
        XCTAssertEqual(FileOpErrorKind.changedDuringMove.allowedResolutions, [.retry, .skip, .cancel])
        XCTAssertEqual(lst(src).st_size, (1 << 20) + 4, "source kept, with the new bytes")
        XCTAssertEqual(names(d), [], "partial removed, nothing landed")
        XCTAssertEqual(o.skipped, [SkippedItem(url: src, reason: .changedDuringMove)])
        XCTAssertEqual(o.record.actions, [])
        let entries = await journal.entries()
        XCTAssertEqual(entries, [])
    }

    func testChangedDuringMoveRetryMovesTheNewContent() async throws {
        let src = try bigFile("src/log.txt", bytes: 1 << 20)
        let d = try dir("d")
        let srcPath = src.path
        let once = EventLog()
        var tuning = FileOpTuning(faultHook: { point, _ in
            guard point == .afterPartialCopy, once.all.isEmpty, let h = FileHandle(forWritingAtPath: srcPath) else { return }
            once.add("appended")
            h.seekToEndOfFile(); h.write(Data("more".utf8)); h.closeFile()
        })
        tuning.forceCrossVolume = true
        let (queue, _) = makeQueue(interaction: ScriptedInteraction(errors: [.retry]), tuning: tuning)
        _ = try await run(.move(sources: [src], destination: d), on: queue)
        XCTAssertFalse(exists(src))
        XCTAssertEqual(lst(url("d/log.txt")).st_size, (1 << 20) + 4)
    }

    func testCrossVolumeCopyFailureRemovesPartialAndKeepsSource() async throws {
        try file("src/T/a", "A"); try file("src/T/secret", "S")
        XCTAssertEqual(chmod(url("src/T/secret").path, 0o000), 0)
        var tuning = FileOpTuning(); tuning.forceCrossVolume = true; tuning.allowClone = false
        let (queue, _) = makeQueue(interaction: ScriptedInteraction(errors: [.skip]), tuning: tuning)
        let d = try dir("d")
        _ = try await run(.move(sources: [url("src/T")], destination: d), on: queue)
        XCTAssertEqual(names(d), [])
        XCTAssertEqual(names(url("src/T")), ["a", "secret"])
    }

    func testMoveConflictKeepBoth() async throws {
        let a = try file("src/a.txt", "new"); try file("d/a.txt", "old")
        let (queue, _) = makeQueue(interaction: ScriptedInteraction(conflicts: [.one(.keepBoth)]))
        _ = try await run(.move(sources: [a], destination: url("d")), on: queue)
        XCTAssertEqual(text(url("d/a.txt")), "old")
        XCTAssertEqual(text(url("d/a 2.txt")), "new")
        XCTAssertFalse(exists(a))
    }
}
