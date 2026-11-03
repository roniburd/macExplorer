import XCTest
import Synchronization
import Darwin
@testable import Core
import MacxFS

final class TrashDeleteTests: FileOpsTestCase {
    func testTrashRecordsResultingURLAndPostsRemoval() async throws {
        let a = try file("d/a.txt", "A")
        let inode = lst(a).st_ino
        let (queue, _) = makeQueue()
        let o = try await run(.trash([a]), on: queue)
        XCTAssertFalse(exists(a))
        guard case .trashed(let original, let trashURL, let id)? = o.record.actions.first else { return XCTFail("\(o.record)") }
        XCTAssertEqual(original, a); XCTAssertEqual(id.inode, inode)
        XCTAssertEqual(text(trashURL), "A")
        XCTAssertEqual(o.localChanges.first?.removed, ["a.txt"])
        XCTAssertTrue(o.record.isUndoable)
    }

    func testNoTrashFallsBackToConfirmedPermanentDelete() async throws {
        let a = try file("nt/a.txt")
        let scripted = ScriptedInteraction(noTrash: [true])
        let (queue, _) = makeQueue(interaction: scripted, trash: SandboxTrash(directory: trashDir, refusingPathsUnder: [url("nt")]))
        let o = try await run(.trash([a]), on: queue)
        XCTAssertEqual(scripted.askedNoTrash(), [[a]])
        XCTAssertFalse(exists(a))
        XCTAssertEqual(o.record.actions, [.deleted(a)])
        XCTAssertFalse(o.record.isUndoable)
    }

    func testNoTrashDeclinedKeepsItem() async throws {
        let a = try file("nt/a.txt")
        let (queue, _) = makeQueue(interaction: ScriptedInteraction(noTrash: [false]),
                                   trash: SandboxTrash(directory: trashDir, refusingPathsUnder: [url("nt")]))
        let o = try await run(.trash([a]), on: queue)
        XCTAssertTrue(exists(a))
        XCTAssertEqual(o.skipped, [SkippedItem(url: a, reason: .noTrash)])
    }

    func testTrashLockedItemOffersUnlockAndContinue() async throws {
        let a = try file("a.txt")
        XCTAssertEqual(lchflags(a.path, UInt32(UF_IMMUTABLE)), 0)
        let scripted = ScriptedInteraction(errors: [.unlockAndContinue])
        let (queue, _) = makeQueue(interaction: scripted)
        _ = try await run(.trash([a]), on: queue)
        XCTAssertEqual(scripted.askedErrors().map(\.kind), [.locked])
        XCTAssertFalse(exists(a))
    }

    func testDeletePermanentlyRemovesTreeWithProgress() async throws {
        for i in 0..<50 { try file("T/f\(i)") }
        try file("T/sub/g")
        let (queue, _) = makeQueue()
        let consumer = Task { () -> JobSnapshot? in
            for await e in queue.events { if case .finished(let s, _) = e { return s } }
            return nil
        }
        let o = try await run(.delete([url("T")]), on: queue)
        let final = await consumer.value
        XCTAssertFalse(exists(url("T")))
        XCTAssertEqual(o.record.actions, [.deleted(url("T"))])
        XCTAssertGreaterThanOrEqual(final?.progress.itemsDone ?? 0, 52)
        XCTAssertEqual(final?.progress.itemsTotal, 53)
    }

    func testDeleteLockedTreeUnlockAndContinue() async throws {
        try file("T/f")
        XCTAssertEqual(lchflags(url("T/f").path, UInt32(UF_IMMUTABLE)), 0)
        let scripted = ScriptedInteraction(errors: [.unlockAndContinue])
        let (queue, _) = makeQueue(interaction: scripted)
        _ = try await run(.delete([url("T")]), on: queue)
        XCTAssertEqual(scripted.askedErrors().map(\.kind), [.locked])
        XCTAssertFalse(exists(url("T")))
    }

    func testAliasResolvesToOriginal() async throws {
        let a = try file("src/a.txt", "A")
        let d = try dir("d")
        let (queue, _) = makeQueue()
        let o = try await run(.alias(sources: [a], destination: d), on: queue)
        let alias = url("d/a.txt alias")
        XCTAssertEqual(o.created, [alias])
        let resolved = try URL(resolvingAliasFileAt: alias)
        XCTAssertEqual(resolved.resolvingSymlinksInPath().path, a.resolvingSymlinksInPath().path)
        let o2 = try await run(.alias(sources: [a], destination: d), on: queue)
        XCTAssertEqual(o2.created.map(\.lastPathComponent), ["a.txt alias 2"])
    }

    func testSymlinkIsRelativeOnSameVolume() async throws {
        let a = try file("src/a.txt", "A")
        let d = try dir("d")
        let (queue, _) = makeQueue()
        _ = try await run(.symlink(sources: [a], destination: d), on: queue)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: url("d/a.txt").path), "../src/a.txt")
        XCTAssertEqual(text(url("d/a.txt")), "A")
        _ = try await run(.symlink(sources: [a], destination: url("src")), on: queue)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: url("src/a.txt symlink").path), "a.txt")
    }

    func testSymlinkIsAbsoluteAcrossVolumes() async throws {
        let mnt = try image(.hfsPlus, sizeMB: 16)
        let a = try file("a.txt", "A")
        let (queue, _) = makeQueue()
        _ = try await run(.symlink(sources: [a], destination: mnt), on: queue)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: mnt.appending(path: "a.txt").path), a.path)
    }

    func testSetAttributesRecordsOldAndNewValues() async throws {
        let a = try file("a.txt")
        let quarantine = Array("0081;5f000000;Safari;".utf8)
        XCTAssertEqual(setxattr(a.path, AttributeJobs.quarantineName, quarantine, quarantine.count, 0, XATTR_NOFOLLOW), 0)
        let (queue, _) = makeQueue()
        let locked = try await run(.setAttributes([a], .locked(true)), on: queue)
        XCTAssertNotEqual(lst(a).st_flags & UInt32(UF_IMMUTABLE), 0)
        XCTAssertEqual(locked.record.actions, [.attributesChanged(a, old: AttributeSnapshot(locked: false), new: AttributeSnapshot(locked: true))])
        _ = try await run(.setAttributes([a], .locked(false)), on: queue)
        let hidden = try await run(.setAttributes([a], .hidden(true)), on: queue)
        XCTAssertNotEqual(lst(a).st_flags & UInt32(UF_HIDDEN), 0)
        XCTAssertEqual(hidden.localChanges.first?.modified, ["a.txt"])
        _ = try await run(.setAttributes([a], .extensionHidden(true)), on: queue)
        XCTAssertEqual(try URL(filePath: a.path).resourceValues(forKeys: [.hasHiddenExtensionKey]).hasHiddenExtension, true)
        let perms = try await run(.setAttributes([a], .permissions(0o600)), on: queue)
        XCTAssertEqual(lst(a).st_mode & 0o7777, 0o600)
        XCTAssertEqual(perms.record.actions, [.attributesChanged(a, old: AttributeSnapshot(mode: 0o644), new: AttributeSnapshot(mode: 0o600))])
        let q = try await run(.setAttributes([a], .removeQuarantine), on: queue)
        XCTAssertEqual(getxattr(a.path, AttributeJobs.quarantineName, nil, 0, 0, XATTR_NOFOLLOW), -1)
        XCTAssertEqual(q.record.actions, [.attributesChanged(a, old: AttributeSnapshot(quarantine: Data(quarantine)), new: AttributeSnapshot(quarantine: Data()))])
    }

    func testPermissionsOnSymlinkNeverFollowTheLink() async throws {
        let target = try file("target.txt")
        XCTAssertEqual(chmod(target.path, 0o644), 0)
        let link = url("link")
        XCTAssertEqual(symlink(target.path, link.path), 0)
        let linkMode = lst(link).st_mode & 0o7777
        let (queue, _) = makeQueue()
        let o = try await run(.setAttributes([link], .permissions(0o600)), on: queue)
        XCTAssertEqual(lst(target).st_mode & 0o7777, 0o644, "the link's target is untouched")
        XCTAssertEqual(lst(link).st_mode & 0o7777, 0o600)
        _ = try await run(.undo(o.record), on: queue)
        XCTAssertEqual(lst(target).st_mode & 0o7777, 0o644, "undo does not follow the link either")
        XCTAssertEqual(lst(link).st_mode & 0o7777, linkMode)
    }

    func testChmodRecursiveAppliesChildrenFirstAndRecords() async throws {
        try file("T/sub/f"); try file("T/g")
        let (queue, _) = makeQueue()
        let o = try await run(.chmodRecursive(url("T"), ModeChange(mode: 0o700)), on: queue)
        for rel in ["T", "T/sub", "T/sub/f", "T/g"] { XCTAssertEqual(lst(url(rel)).st_mode & 0o777, 0o700, rel) }
        XCTAssertEqual(o.record.actions.count, 4)
        guard case .modeChanged(let first, _, _)? = o.record.actions.first,
              case .modeChanged(let last, let old, let new)? = o.record.actions.last else { return XCTFail() }
        XCTAssertNotEqual(first, url("T"), "children first")
        XCTAssertEqual(last, url("T")); XCTAssertEqual(old, 0o755); XCTAssertEqual(new, 0o700)
    }

    func testCancelledChmodRecursiveRecordsOnlyAppliedChanges() async throws {
        for i in 0..<600 { try file("T/f\(i)") }
        final class Holder: Sendable {
            let queue = Mutex<FileOpQueue?>(nil)
            let calls = Mutex(0)
        }
        let holder = Holder()
        let tuning = FileOpTuning(faultHook: { point, id in
            guard point == .modeBatchCheckpoint, holder.calls.withLock({ $0 += 1; return $0 }) == 2,
                  let queue = holder.queue.withLock({ $0 }) else { return }
            Task { await queue.cancel(id) }
            usleep(300_000)                                                // let the cancel land before the checkpoint
        })
        let (queue, _) = makeQueue(tuning: tuning)
        holder.queue.withLock { $0 = queue }
        let o = try await run(.chmodRecursive(url("T"), ModeChange(mode: 0o700)), on: queue)
        XCTAssertTrue(o.wasCancelled)
        XCTAssertEqual(o.record.actions.count, 256, "only the changes tried before the cancel")
        let changed = (0..<600).filter { lst(url("T/f\($0)")).st_mode & 0o777 == 0o700 }.count
        XCTAssertEqual(changed, 256)
        let undone = try await run(.undo(o.record), on: queue)
        XCTAssertEqual(undone.skipped, [])
    }

    func testChmodRecursiveFilesOnly() async throws {
        try file("T/f")
        let (queue, _) = makeQueue()
        _ = try await run(.chmodRecursive(url("T"), ModeChange(mode: 0o600, applyToDirectories: false, applyToFiles: true)), on: queue)
        XCTAssertEqual(lst(url("T")).st_mode & 0o777, 0o755)
        XCTAssertEqual(lst(url("T/f")).st_mode & 0o777, 0o600)
    }
}
