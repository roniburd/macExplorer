import XCTest
import Darwin
@testable import Core
import MacxFS

/// Texts of every file named `name` anywhere under the sandbox trash.
func trashedTexts(_ name: String, in trashDir: URL) -> [String] {
    let e = FileManager.default.enumerator(atPath: trashDir.path)
    var out: [String] = []
    while let rel = e?.nextObject() as? String {
        guard (rel as NSString).lastPathComponent == name,
              let data = try? Data(contentsOf: trashDir.appending(path: rel)) else { continue }
        out.append(String(decoding: data, as: UTF8.self))
    }
    return out.sorted()
}

final class UndoTests: FileOpsTestCase {
    private func trashed(_ name: String) -> [String] { trashedTexts(name, in: trashDir) }
    private func inTrash(_ name: String) -> Bool {
        let e = FileManager.default.enumerator(atPath: trashDir.path)
        while let rel = e?.nextObject() as? String { if (rel as NSString).lastPathComponent == name { return true } }
        return false
    }

    func testStepsInvertEveryActionInReverseOrder() {
        let id = FileIdentity(device: 1, inode: 2)
        let u = URL(filePath: "/s/a"), v = URL(filePath: "/s/b"), t = URL(filePath: "/s/.trash/x/a")
        let record = JobRecord(id: JobID(), verb: .moving, actions: [
            .created(u, id), .createdDirectory(v, id), .moved(from: u, to: v, id), .renamed(from: u, to: v, id),
            .trashed(original: u, trashURL: t, id), .replaced(original: v, trashURL: t, id),
            .modeChanged(u, old: 0o644, new: 0o600),
            .attributesChanged(u, old: AttributeSnapshot(locked: false), new: AttributeSnapshot(locked: true)),
        ])
        XCTAssertEqual(UndoPlanner.steps(for: record), [
            .restoreAttributes(u, expected: AttributeSnapshot(locked: true), restore: AttributeSnapshot(locked: false)),
            .restoreMode(u, expected: 0o600, restore: 0o644),
            .moveBack(current: t, original: v, id),
            .moveBack(current: t, original: u, id),
            .renameBack(current: v, original: u, id),
            .moveBack(current: v, original: u, id),
            .removeDirectoryIfEmpty(v, id),
            .trash(u, id),
        ])
        XCTAssertEqual(UndoPlanner.steps(for: JobRecord(id: JobID(), verb: .makingSymlink, actions: [.created(u, id)])), [.remove(u, id)])
        XCTAssertEqual(UndoPlanner.steps(for: JobRecord(id: JobID(), verb: .makingAlias, actions: [.created(u, id)])), [.remove(u, id)])
        XCTAssertNil(UndoPlanner.steps(for: JobRecord(id: JobID(), verb: .deleting, actions: [.deleted(u)])))
        XCTAssertNil(UndoPlanner.steps(for: JobRecord(id: JobID(), verb: .copying, actions: [])))
    }

    func testUndoCopyTrashesCreatedItemsAndRedoBringsThemBack() async throws {
        let a = try file("src/a.txt", "A"); try file("src/T/x", "X")
        let d = try dir("d")
        let (queue, _) = makeQueue()
        let copied = try await run(.copy(sources: [a, url("src/T")], destination: d), on: queue)
        let undone = try await run(.undo(copied.record), on: queue)
        XCTAssertEqual(names(d), [])
        XCTAssertEqual(text(a), "A")
        XCTAssertEqual(text(url("src/T/x")), "X", "sources untouched")
        XCTAssertEqual(trashed("a.txt"), ["A"], "copies go to the trash, never deleted")
        XCTAssertEqual(undone.record.verb, .undoing)
        XCTAssertEqual(undone.record.actions.count, 2)
        XCTAssertTrue(undone.record.actions.allSatisfy { if case .trashed = $0 { true } else { false } })
        XCTAssertEqual(Set(undone.localChanges.flatMap(\.removed)), ["a.txt", "T"])
        let redone = try await run(.redo(undone.record), on: queue)
        XCTAssertEqual(names(d), ["T", "a.txt"])
        XCTAssertEqual(text(url("d/T/x")), "X")
        XCTAssertEqual(redone.record.verb, .redoing)
        XCTAssertEqual(Set(redone.created), [url("d/a.txt"), url("d/T")])
        XCTAssertEqual(trashed("a.txt"), [])
    }

    func testUndoSameVolumeMoveMovesBackKeepingIdentity() async throws {
        let a = try file("src/a.txt", "A")
        let inode = lst(a).st_ino
        let (queue, _) = makeQueue()
        let moved = try await run(.move(sources: [a], destination: try dir("d")), on: queue)
        let undone = try await run(.undo(moved.record), on: queue)
        XCTAssertEqual(lst(a).st_ino, inode, "renamed back, not copied")
        XCTAssertFalse(exists(url("d/a.txt")))
        guard case .moved(let from, let to, _)? = undone.record.actions.first else { return XCTFail("\(undone.record)") }
        XCTAssertEqual(from, url("d/a.txt"))
        XCTAssertEqual(to, a)
        XCTAssertEqual(undone.created, [a])
        XCTAssertEqual(undone.localChanges.first { $0.directory.lastPathComponent == "src" }?.select, ["a.txt"])
    }

    func testUndoCrossVolumeMoveMovesBackAcrossVolumes() async throws {
        try file("src/T/x", "X")
        var tuning = FileOpTuning(); tuning.forceCrossVolume = true
        let (queue, journal) = makeQueue(tuning: tuning)
        let moved = try await run(.move(sources: [url("src/T")], destination: try dir("d")), on: queue)
        XCTAssertFalse(exists(url("src/T")))
        _ = try await run(.undo(moved.record), on: queue)
        XCTAssertEqual(text(url("src/T/x")), "X")
        XCTAssertFalse(exists(url("d/T")))
        XCTAssertEqual(names(url("src")).filter { PartialName.isPartial($0) }, [])
        let entries = await journal.entries()
        XCTAssertEqual(entries, [])
    }

    func testUndoRenameRenamesBack() async throws {
        let a = try file("d/a.txt", "A")
        let (queue, _) = makeQueue()
        let renamed = try await run(.rename(a, to: "b.txt"), on: queue)
        let undone = try await run(.undo(renamed.record), on: queue)
        XCTAssertEqual(names(url("d")), ["a.txt"])
        XCTAssertEqual(undone.localChanges.first?.renamed, [LocalChange.Rename(from: "b.txt", to: "a.txt")])
    }

    func testUndoCaseOnlyRenameIsNotAnOccupiedPath() async throws {
        let a = try file("d/a.txt", "A")
        let scripted = ScriptedInteraction()
        let (queue, _) = makeQueue(interaction: scripted)
        let renamed = try await run(.rename(a, to: "A.txt"), on: queue)
        XCTAssertEqual(names(url("d")), ["A.txt"])
        _ = try await run(.undo(renamed.record), on: queue)
        XCTAssertEqual(names(url("d")), ["a.txt"])
        XCTAssertEqual(scripted.askedConflicts().count, 0, "the original spelling names the same file, not an occupant")
    }

    func testUndoTrashRestoresOriginalPath() async throws {
        let a = try file("d/a.txt", "keep me")
        let (queue, _) = makeQueue()
        let trashedJob = try await run(.trash([a]), on: queue)
        XCTAssertFalse(exists(a))
        let undone = try await run(.undo(trashedJob.record), on: queue)
        XCTAssertEqual(text(a), "keep me")
        XCTAssertEqual(undone.created, [a])
        XCTAssertEqual(trashed("a.txt"), [])
    }

    func testUndoNewFolderTrashesIt() async throws {
        let d = try dir("d")
        let (queue, _) = makeQueue()
        let made = try await run(.newItem(.folder, in: d), on: queue)
        XCTAssertEqual(names(d), ["New Folder"])
        _ = try await run(.undo(made.record), on: queue)
        XCTAssertEqual(names(d), [])
        XCTAssertTrue(inTrash("New Folder"))
    }

    func testUndoCopyThatReplacedRestoresTheDisplacedItem() async throws {
        let a = try file("src/a.txt", "new"); try file("d/a.txt", "old")
        let (queue, _) = makeQueue(interaction: ScriptedInteraction(conflicts: [.one(.replace)]))
        let copied = try await run(.copy(sources: [a], destination: url("d")), on: queue)
        XCTAssertEqual(text(url("d/a.txt")), "new")
        _ = try await run(.undo(copied.record), on: queue)
        XCTAssertEqual(text(url("d/a.txt")), "old", "the replaced item is back from its stored trash URL")
        XCTAssertEqual(trashed("a.txt"), ["new"], "the new copy went to the trash")
        XCTAssertEqual(text(a), "new")
    }

    func testUndoMergeMoveRecreatesTheRemovedSourceFolderAndRedoRemovesItAgain() async throws {
        try file("src/F/a", "A"); try file("src/F/b", "new b")
        try file("d/F/b", "old b"); try file("d/F/x", "X")
        let (queue, _) = makeQueue(interaction: ScriptedInteraction(conflicts: [.one(.merge), .one(.replace)]))
        let moved = try await run(.move(sources: [url("src/F")], destination: url("d")), on: queue)
        XCTAssertFalse(exists(url("src/F")), "merge-move removed the emptied source folder")
        let undone = try await run(.undo(moved.record), on: queue)
        XCTAssertEqual(names(url("src/F")), ["a", "b"])
        XCTAssertEqual(text(url("src/F/b")), "new b")
        XCTAssertEqual(names(url("d/F")), ["b", "x"])
        XCTAssertEqual(text(url("d/F/b")), "old b")
        guard case .createdDirectory(let made, _)? = undone.record.actions.first else { return XCTFail("\(undone.record)") }
        XCTAssertEqual(made.path, url("src/F").path)
        _ = try await run(.redo(undone.record), on: queue)
        XCTAssertFalse(exists(url("src/F")), "the folder undo re-created is removed once empty")
        XCTAssertEqual(names(url("d/F")), ["a", "b", "x"])
        XCTAssertEqual(text(url("d/F/b")), "new b")
        XCTAssertEqual(trashed("b"), ["old b"])
    }

    func testUndoChmodRecursiveRestoresEveryRecordedMode() async throws {
        try file("T/sub/f"); try file("T/g")
        let modes: [(String, mode_t)] = [("T", 0o755), ("T/sub", 0o750), ("T/sub/f", 0o640), ("T/g", 0o644)]
        for (rel, m) in modes { XCTAssertEqual(chmod(url(rel).path, m), 0) }
        let (queue, _) = makeQueue()
        let changed = try await run(.chmodRecursive(url("T"), ModeChange(mode: 0o700)), on: queue)
        XCTAssertEqual(changed.record.actions.count, 4)
        let undone = try await run(.undo(changed.record), on: queue)
        for (rel, m) in modes { XCTAssertEqual(lst(url(rel)).st_mode & 0o7777, m, rel) }
        XCTAssertEqual(undone.record.actions.count, 4)
        XCTAssertEqual(undone.skipped, [])
    }

    func testUndoChmodSkipsItemsWhoseModeChangedSince() async throws {
        try file("T/f")
        XCTAssertEqual(chmod(url("T").path, 0o755), 0)
        XCTAssertEqual(chmod(url("T/f").path, 0o644), 0)
        let (queue, _) = makeQueue()
        let changed = try await run(.chmodRecursive(url("T"), ModeChange(mode: 0o700)), on: queue)
        XCTAssertEqual(chmod(url("T/f").path, 0o600), 0)                  // changed behind our back
        let undone = try await run(.undo(changed.record), on: queue)
        XCTAssertEqual(undone.skipped, [SkippedItem(url: url("T/f"), reason: .changedDuringMove)])
        XCTAssertEqual(lst(url("T/f")).st_mode & 0o7777, 0o600, "the external change is kept")
        XCTAssertEqual(lst(url("T")).st_mode & 0o7777, 0o755)
    }

    func testUndoSetAttributesRestoresPreviousValues() async throws {
        let a = try file("a.txt")
        let quarantine = Array("0081;5f000000;Safari;".utf8)
        XCTAssertEqual(setxattr(a.path, AttributeJobs.quarantineName, quarantine, quarantine.count, 0, XATTR_NOFOLLOW), 0)
        let (queue, _) = makeQueue()
        let hidden = try await run(.setAttributes([a], .hidden(true)), on: queue)
        let unquarantined = try await run(.setAttributes([a], .removeQuarantine), on: queue)
        let locked = try await run(.setAttributes([a], .locked(true)), on: queue)
        _ = try await run(.undo(locked.record), on: queue)                // newest first, like the stack
        XCTAssertEqual(lst(a).st_flags & UInt32(UF_IMMUTABLE), 0)
        _ = try await run(.undo(unquarantined.record), on: queue)
        XCTAssertEqual(AttributeJobs.readXattr(a.path, AttributeJobs.quarantineName), Data(quarantine), "saved xattr rewritten")
        let undoneHidden = try await run(.undo(hidden.record), on: queue)
        XCTAssertEqual(lst(a).st_flags & UInt32(UF_HIDDEN), 0)
        XCTAssertEqual(undoneHidden.record.actions,
                       [.attributesChanged(a, old: AttributeSnapshot(hidden: true), new: AttributeSnapshot(hidden: false))])
        XCTAssertEqual(undoneHidden.localChanges.first?.modified, ["a.txt"])
    }

    func testUndoAliasAndSymlinkRemovesThemAndLeavesNothingToRedo() async throws {
        let a = try file("src/a.txt", "A")
        let d = try dir("d")
        let (queue, _) = makeQueue()
        let alias = try await run(.alias(sources: [a], destination: d), on: queue)
        let link = try await run(.symlink(sources: [a], destination: d), on: queue)
        let undoneLink = try await run(.undo(link.record), on: queue)
        let undoneAlias = try await run(.undo(alias.record), on: queue)
        XCTAssertEqual(names(d), [])
        XCTAssertEqual(text(a), "A", "the original is untouched")
        XCTAssertEqual(undoneLink.record.actions, [.deleted(url("d/a.txt"))])
        XCTAssertFalse(undoneAlias.record.isUndoable)
        XCTAssertFalse(inTrash("a.txt alias"), "removed, not trashed (§6.6)")
    }

    func testUndoSkipsItemsThatWereRemovedOrReplacedAndListsThem() async throws {
        let a = try file("src/a.txt"), b = try file("src/b.txt")
        let (queue, _) = makeQueue()
        let copied = try await run(.copy(sources: [a, b], destination: try dir("d")), on: queue)
        try FileManager.default.removeItem(at: url("d/a.txt"))                         // gone
        try file("d/b.new", "saved by an editor")
        XCTAssertEqual(Darwin.rename(url("d/b.new").path, url("d/b.txt").path), 0)     // atomic save: new identity
        let undone = try await run(.undo(copied.record), on: queue)
        XCTAssertEqual(undone.skipped, [SkippedItem(url: url("d/b.txt"), reason: .changedDuringMove),
                                        SkippedItem(url: url("d/a.txt"), reason: .sourceGone)])
        XCTAssertEqual(text(url("d/b.txt")), "saved by an editor", "a changed item is never trashed")
        XCTAssertEqual(undone.record.actions, [])
    }

    /// Slice Review Focus 5.
    func testUndoIntoOccupiedPathAsksConflictAndNeverOverwrites() async throws {
        let a = try file("src/a.txt", "moved")
        let scripted = ScriptedInteraction()                                          // default answer: Skip
        let (queue, _) = makeQueue(interaction: scripted)
        let moved = try await run(.move(sources: [a], destination: try dir("d")), on: queue)
        try file("src/a.txt", "new at the old place")
        let undone = try await run(.undo(moved.record), on: queue)
        XCTAssertEqual(scripted.askedConflicts().count, 1)
        XCTAssertEqual(scripted.askedConflicts().first?.pair.source.url, url("d/a.txt"))
        XCTAssertEqual(scripted.askedConflicts().first?.pair.destination.url, a)
        XCTAssertEqual(text(a), "new at the old place")
        XCTAssertEqual(text(url("d/a.txt")), "moved")
        XCTAssertEqual(undone.skipped, [SkippedItem(url: url("d/a.txt"), reason: nil)])
    }

    func testUndoIntoOccupiedPathKeepBothLandsUnderTheNextFreeName() async throws {
        let a = try file("src/a.txt", "moved")
        let (queue, _) = makeQueue(interaction: ScriptedInteraction(conflicts: [.one(.keepBoth)]))
        let moved = try await run(.move(sources: [a], destination: try dir("d")), on: queue)
        try file("src/a.txt", "new")
        _ = try await run(.undo(moved.record), on: queue)
        XCTAssertEqual(names(url("src")), ["a 2.txt", "a.txt"])
        XCTAssertEqual(text(url("src/a 2.txt")), "moved")
        XCTAssertEqual(text(a), "new")
    }

    func testUndoIntoOccupiedPathReplaceTrashesTheOccupantAndRedoRestoresIt() async throws {
        let a = try file("src/a.txt", "moved")
        let (queue, _) = makeQueue(interaction: ScriptedInteraction(conflicts: [.one(.replace)]))
        let moved = try await run(.move(sources: [a], destination: try dir("d")), on: queue)
        try file("src/a.txt", "occupant")
        let undone = try await run(.undo(moved.record), on: queue)
        XCTAssertEqual(text(a), "moved")
        XCTAssertEqual(trashed("a.txt"), ["occupant"], "the occupant is trashed, never deleted")
        XCTAssertTrue(undone.record.actions.contains { if case .replaced = $0 { true } else { false } })
        _ = try await run(.redo(undone.record), on: queue)
        XCTAssertEqual(text(url("d/a.txt")), "moved")
        XCTAssertEqual(text(a), "occupant", "redo puts the displaced occupant back")
        XCTAssertEqual(trashed("a.txt"), [])
    }

    func testPartlyCompletedJobUndoesOnlyTheItemsThatWereDone() async throws {
        let a = try file("a.txt")
        let (queue, _) = makeQueue()                                                   // missing source: plan refusal, Skip
        let copied = try await run(.copy(sources: [a, url("missing.txt")], destination: try dir("d")), on: queue)
        XCTAssertEqual(copied.skipped.map(\.url), [url("missing.txt")])
        _ = try await run(.undo(copied.record), on: queue)
        XCTAssertEqual(names(url("d")), [])
        XCTAssertTrue(exists(a))
    }

    func testUndoOfANonUndoableRecordDoesNothing() async throws {
        let a = try file("a.txt")
        let (queue, _) = makeQueue()
        let record = JobRecord(id: JobID(), verb: .deleting,
                               actions: [.created(a, FileIdentity(device: 0, inode: 0)), .deleted(url("gone"))])
        let o = try await run(.undo(record), on: queue)
        XCTAssertEqual(o.record.actions, [])
        XCTAssertTrue(exists(a), "a record with a permanent delete is not undoable at all")
    }
}

@MainActor
final class UndoStackTests: FileOpsTestCase {
    private func copyJob(_ w: FileOpsWorld, _ queue: FileOpQueue) async throws -> JobOutcome {
        let a = try w.file("src/a.txt", "A")
        return await w.run(.copy(sources: [a], destination: try w.dir("d")), on: queue)
    }
    private func emptyOutcome(_ actions: [ItemAction]) -> JobOutcome {
        JobOutcome(record: JobRecord(id: JobID(), verb: .deleting, actions: actions), skipped: [], wasCancelled: false,
                   created: [], localChanges: [])
    }

    func testRegistersOneNamedEntryPerUndoableJob() async throws {
        let w = world
        let (queue, _) = w.makeQueue()
        let stack = FileOpUndoStack(queue: queue)
        XCTAssertFalse(stack.canUndo)
        stack.register(try await copyJob(w, queue), actionName: "Copy")
        XCTAssertTrue(stack.canUndo)
        XCTAssertFalse(stack.canRedo)
        XCTAssertEqual(stack.undoManager.undoActionName, "Copy")
        stack.register(emptyOutcome([.deleted(w.url("x"))]), actionName: "Delete")
        stack.register(emptyOutcome([]), actionName: "Nothing")
        XCTAssertEqual(stack.undoManager.undoActionName, "Copy", "permanent delete and empty jobs register nothing")
    }

    func testUndoAndRedoThroughTheUndoManagerRunAsJobs() async throws {
        let w = world
        let (queue, _) = w.makeQueue()
        let stack = FileOpUndoStack(queue: queue)
        stack.register(try await copyJob(w, queue), actionName: "Copy")
        let target = w.url("d/a.txt").path
        stack.undoManager.undo()
        XCTAssertTrue(stack.canRedo, "the redo entry is registered synchronously, while undoing")
        XCTAssertEqual(stack.undoManager.redoActionName, "Copy")
        await w.waitUntil { !onDisk(target) }
        stack.undoManager.redo()
        XCTAssertTrue(stack.canUndo)
        XCTAssertEqual(stack.undoManager.undoActionName, "Copy")
        await w.waitUntil { onDisk(target) }
        XCTAssertEqual(w.text(w.url("d/a.txt")), "A")
    }

    func testRedoPressedBeforeTheUndoJobFinishedRunsAfterIt() async throws {
        let w = world
        let (queue, _) = w.makeQueue()
        let stack = FileOpUndoStack(queue: queue)
        stack.register(try await copyJob(w, queue), actionName: "Copy")
        let inverses = Task { () -> [JobVerb] in              // the copy's events are still buffered; skip them
            var verbs: [JobVerb] = []
            for await event in queue.events {
                if case .finished(let s, _) = event, s.description.verb != .copying { verbs.append(s.description.verb) }
                if verbs.count == 2 { break }
            }
            return verbs
        }
        stack.undoManager.undo()
        stack.undoManager.redo()                        // the undo job may still be queued
        let verbs = await inverses.value
        XCTAssertEqual(verbs, [.undoing, .redoing], "redo ran after undo, never before it")
        XCTAssertTrue(onDisk(w.url("d/a.txt").path))
        XCTAssertEqual(trashedTexts("a.txt", in: w.trashDir), [])
    }

    func testAnInverseThatDidNothingLeavesNoRedo() async throws {
        let w = world
        let (queue, _) = w.makeQueue()
        let stack = FileOpUndoStack(queue: queue)
        stack.register(try await copyJob(w, queue), actionName: "Copy")
        try FileManager.default.removeItem(at: w.url("d/a.txt"))     // gone behind our back
        stack.undoManager.undo()
        XCTAssertTrue(stack.canRedo)
        await w.waitUntil { @MainActor in !stack.canRedo }
        XCTAssertFalse(stack.canUndo)
    }

    func testANewJobClearsRedo() async throws {
        let w = world
        let (queue, _) = w.makeQueue()
        let stack = FileOpUndoStack(queue: queue)
        stack.register(try await copyJob(w, queue), actionName: "Copy")
        stack.undoManager.undo()
        let target = w.url("d/a.txt").path
        await w.waitUntil { !onDisk(target) }
        XCTAssertTrue(stack.canRedo)
        let made = await w.run(.newItem(.folder, in: w.url("d")), on: queue)
        stack.register(made, actionName: "New Folder")
        XCTAssertFalse(stack.canRedo)
        XCTAssertEqual(stack.undoManager.undoActionName, "New Folder")
    }

    func testFieldEditorManagersAreSeparateFromTheFileStack() {
        let (queue, _) = world.makeQueue()
        let stack = FileOpUndoStack(queue: queue)
        let m1 = stack.makeFieldEditorUndoManager(), m2 = stack.makeFieldEditorUndoManager()
        XCTAssertFalse(m1 === stack.undoManager)
        XCTAssertFalse(m1 === m2, "one manager per edit, discarded when editing ends")
        XCTAssertTrue(m1.groupsByEvent, "typing undo groups by event")
        XCTAssertFalse(stack.undoManager.groupsByEvent, "file-operation entries are explicit groups")
    }
}
