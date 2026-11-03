import XCTest
import Darwin
@testable import Core
import MacxFS

final class ConflictTests: FileOpsTestCase {
    /// Every file named `name` anywhere under the sandbox trash, with its text.
    private func trashed(_ name: String) -> [String] {
        let e = FileManager.default.enumerator(atPath: trashDir.path)
        var out: [String] = []
        while let rel = e?.nextObject() as? String {
            guard (rel as NSString).lastPathComponent == name, let t = text(trashDir.appending(path: rel)) else { continue }
            out.append(t)
        }
        return out
    }
    private func partials(_ dir: URL) -> [String] { names(dir).filter { PartialName.isPartial($0) } }

    func testReplaceCopyTrashesExistingAfterVerifiedCopy() async throws {
        let a = try file("src/a", "new"); try file("d/a", "old")
        let (queue, journal) = makeQueue(interaction: ScriptedInteraction(conflicts: [.one(.replace)]))
        let o = try await run(.copy(sources: [a], destination: url("d")), on: queue)
        XCTAssertEqual(text(url("d/a")), "new")
        XCTAssertEqual(text(a), "new")
        XCTAssertEqual(trashed("a"), ["old"])
        XCTAssertEqual(partials(url("d")), [])
        guard o.record.actions.count == 2, case .replaced(let original, _, _) = o.record.actions[0],
              case .created(let created, _) = o.record.actions[1] else { return XCTFail("\(o.record.actions)") }
        XCTAssertEqual(original, url("d/a")); XCTAssertEqual(created, url("d/a"))
        let entries = await journal.entries()
        XCTAssertEqual(entries, [])
    }

    func testReplaceSameVolumeMoveTrashesThenRenames() async throws {
        let a = try file("src/a", "new"); try file("d/a", "old")
        let inode = lst(a).st_ino
        let (queue, _) = makeQueue(interaction: ScriptedInteraction(conflicts: [.one(.replace)]))
        let o = try await run(.move(sources: [a], destination: url("d")), on: queue)
        XCTAssertEqual(lst(url("d/a")).st_ino, inode, "renamed, not copied")
        XCTAssertFalse(exists(a))
        XCTAssertEqual(trashed("a"), ["old"])
        guard case .replaced = o.record.actions.first, case .moved = o.record.actions.last else { return XCTFail("\(o.record.actions)") }
    }

    func testReplaceCrossVolumeMove() async throws {
        let a = try file("src/a", "new"); try file("d/a", "old")
        var tuning = FileOpTuning(); tuning.forceCrossVolume = true
        let (queue, _) = makeQueue(interaction: ScriptedInteraction(conflicts: [.one(.replace)]), tuning: tuning)
        _ = try await run(.move(sources: [a], destination: url("d")), on: queue)
        XCTAssertEqual(text(url("d/a")), "new")
        XCTAssertFalse(exists(a))
        XCTAssertEqual(trashed("a"), ["old"])
        XCTAssertEqual(partials(url("d")), [])
    }

    func testReplaceRestoresTrashedItemWhenFinalRenameFails() async throws {
        let a = try file("src/a", "new"); try file("d/a", "old")
        let dPath = url("d").path
        var tuning = FileOpTuning(faultHook: { point, _ in
            guard point == .afterTrashDestination else { return }
            // Make the final rename fail: move the partial out of the way.
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dPath)) ?? []
            if let p = names.first(where: { PartialName.isPartial($0) }) { _ = Darwin.rename(dPath + "/" + p, dPath + "/moved-away") }
        })
        tuning.forceCrossVolume = true
        let scripted = ScriptedInteraction(conflicts: [.one(.replace)], errors: [.skip])
        let (queue, journal) = makeQueue(interaction: scripted, tuning: tuning)
        let o = try await run(.move(sources: [a], destination: url("d")), on: queue)
        XCTAssertEqual(text(url("d/a")), "old", "replaced item restored from the trash")
        XCTAssertEqual(text(a), "new", "source never deleted")
        XCTAssertEqual(trashed("a"), [])
        XCTAssertFalse(o.record.actions.contains { if case .replaced = $0 { true } else { false } })
        XCTAssertEqual(scripted.askedErrors().count, 1)
        let entries = await journal.entries()
        XCTAssertEqual(entries, [])
    }

    func testApplyToAllAnswersEveryRemainingConflict() async throws {
        for n in ["a", "b", "c"] { try file("src/\(n)", "new \(n)"); try file("d/\(n)", "old") }
        let scripted = ScriptedInteraction(conflicts: [.all(.keepBoth)])
        let (queue, _) = makeQueue(interaction: scripted)
        _ = try await run(.copy(sources: ["a", "b", "c"].map { url("src/\($0)") }, destination: url("d")), on: queue)
        XCTAssertEqual(scripted.askedConflicts().count, 1)
        XCTAssertEqual(scripted.askedConflicts().first?.knownRemaining, 3)
        XCTAssertEqual(names(url("d")), ["a", "a 2", "b", "b 2", "c", "c 2"])
    }

    func testPerItemCompareAnswersAndMissingKeysSkip() async throws {
        let a = try file("src/a", "new a"), b = try file("src/b", "new b")
        try file("d/a", "old a"); try file("d/b", "old b")
        let scripted = ScriptedInteraction(conflicts: [.perItem([a: .replace])])
        let (queue, _) = makeQueue(interaction: scripted)
        let o = try await run(.copy(sources: [a, b], destination: url("d")), on: queue)
        XCTAssertEqual(scripted.askedConflicts().count, 1)
        XCTAssertEqual(scripted.askedConflicts().first?.pendingPairs.count, 2)
        XCTAssertEqual(text(url("d/a")), "new a")
        XCTAssertEqual(text(url("d/b")), "old b")
        XCTAssertEqual(o.skipped, [SkippedItem(url: b, reason: nil)])
    }

    func testCancelJobFromConflictStopsEverything() async throws {
        let a = try file("src/a"), b = try file("src/b")
        try file("d/a", "old")
        let (queue, _) = makeQueue(interaction: ScriptedInteraction(conflicts: [.cancelJob]))
        let o = try await run(.copy(sources: [a, b], destination: url("d")), on: queue)
        XCTAssertTrue(o.wasCancelled)
        XCTAssertEqual(names(url("d")), ["a"])
        XCTAssertEqual(text(url("d/a")), "old")
    }

    func testFolderConflictOffersMergeAndMergesCopy() async throws {
        try file("src/F/a", "A"); try file("src/F/b", "new b"); try file("src/F/sub/c", "C")
        try file("d/F/b", "old b"); try file("d/F/x", "X")
        let scripted = ScriptedInteraction(conflicts: [.one(.merge), .one(.replace)])
        let (queue, _) = makeQueue(interaction: scripted)
        _ = try await run(.copy(sources: [url("src/F")], destination: url("d")), on: queue)
        XCTAssertEqual(scripted.askedConflicts().map(\.isFolderMerge), [true, false])
        XCTAssertEqual(names(url("d/F")), ["a", "b", "sub", "x"])
        XCTAssertEqual(text(url("d/F/b")), "new b")
        XCTAssertEqual(text(url("d/F/sub/c")), "C")
        XCTAssertEqual(trashed("b"), ["old b"])
        XCTAssertEqual(names(url("src/F")), ["a", "b", "sub"], "copy leaves the source")
    }

    func testMergeMoveRemovesSourceFolderOnlyWhenEmpty() async throws {
        try file("src/F/a", "A"); try file("src/F/b", "new b"); try file("src/F/sub/c", "C")
        try file("d/F/b", "old b"); try file("d/F/x", "X")
        let (queue, _) = makeQueue(interaction: ScriptedInteraction(conflicts: [.one(.merge), .one(.skip)]))
        _ = try await run(.move(sources: [url("src/F")], destination: url("d")), on: queue)
        XCTAssertEqual(names(url("src/F")), ["b"], "the skipped child stays; its folder stays")
        XCTAssertEqual(names(url("d/F")), ["a", "b", "sub", "x"])
        XCTAssertEqual(text(url("d/F/b")), "old b")
    }

    func testMergeMoveRemovesEmptiedSourceFolder() async throws {
        try file("src/F/a", "A"); try file("src/F/b", "new b")
        try file("d/F/b", "old b")
        let (queue, _) = makeQueue(interaction: ScriptedInteraction(conflicts: [.one(.merge), .one(.replace)]))
        _ = try await run(.move(sources: [url("src/F")], destination: url("d")), on: queue)
        XCTAssertFalse(exists(url("src/F")))
        XCTAssertEqual(text(url("d/F/b")), "new b")
    }

    func testReplaceOnFolderPairMeansMerge() async throws {
        try file("src/F/a", "A"); try file("d/F/x", "X")
        let (queue, _) = makeQueue(interaction: ScriptedInteraction(conflicts: [.one(.replace)]))
        _ = try await run(.copy(sources: [url("src/F")], destination: url("d")), on: queue)
        XCTAssertEqual(names(url("d/F")), ["a", "x"], "folders are merged, never trashed wholesale")
    }

    func testReplaceAcrossDiskImage() async throws {
        let mnt = try image(.hfsPlus, sizeMB: 32)
        let a = try file("src/a", "new")
        try Data("old".utf8).write(to: mnt.appending(path: "a"))
        let (queue, _) = makeQueue(interaction: ScriptedInteraction(conflicts: [.one(.replace)]))
        _ = try await run(.move(sources: [a], destination: mnt), on: queue)
        XCTAssertEqual(text(mnt.appending(path: "a")), "new")
        XCTAssertFalse(exists(a))
        XCTAssertFalse(names(mnt).contains { PartialName.isPartial($0) })
    }
}
