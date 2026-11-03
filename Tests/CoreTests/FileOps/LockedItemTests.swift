import XCTest
import Darwin
import Synchronization
@testable import Core
import MacxFS

/// Locked (uchg) sources: the partial copy inherits UF_IMMUTABLE, which must not block the final rename,
/// and the item must land locked. The source is never unlocked before the move is in place.
final class LockedItemTests: FileOpsTestCase {
    private func lock(_ u: URL) { XCTAssertEqual(lchflags(u.path, lst(u).st_flags | UInt32(UF_IMMUTABLE)), 0) }
    private func isLocked(_ u: URL) -> Bool { lst(u).st_flags & UInt32(UF_IMMUTABLE) != 0 }
    private func partials(_ dir: URL) -> [String] { names(dir).filter { PartialName.isPartial($0) } }

    /// Tuning whose hook records whether `source` was still locked when the source delete began.
    final class Seen: Sendable {
        let value = Mutex<Bool?>(nil)
        func get() -> Bool? { value.withLock { $0 } }
    }
    private func lockProbe(_ source: URL) -> (FileOpTuning, Seen) {
        let seen = Seen()
        let path = source.path
        let tuning = FileOpTuning(faultHook: { point, _ in
            guard point == .beforeSourceDelete else { return }
            var st = stat(); _ = lstat(path, &st)
            seen.value.withLock { $0 = st.st_flags & UInt32(UF_IMMUTABLE) != 0 }
        })
        return (tuning, seen)
    }

    func testCrossVolumeMoveOfLockedFileKeepsLock() async throws {
        let mnt = try image(.hfsPlus, sizeMB: 16)
        let a = try file("src/a", "A")
        lock(a)
        let (tuning, seen) = lockProbe(a)
        let scripted = ScriptedInteraction(errors: [.unlockAndContinue])   // deleting the locked source
        let (queue, _) = makeQueue(interaction: scripted, tuning: tuning)
        let o = try await run(.move(sources: [a], destination: mnt), on: queue)
        let target = mnt.appending(path: "a")
        XCTAssertEqual(text(target), "A")
        XCTAssertTrue(isLocked(target), "lock kept")
        XCTAssertFalse(exists(a))
        XCTAssertEqual(seen.get(), true, "source untouched until the copy was in place")
        XCTAssertEqual(scripted.askedErrors().map(\.url), [a])
        XCTAssertEqual(partials(mnt), [])
        XCTAssertEqual(o.skipped, [])
        guard case .moved(_, let to, _)? = o.record.actions.last else { return XCTFail("\(o.record.actions)") }
        XCTAssertEqual(to, target)
    }

    func testCrossVolumeMoveOfLockedFolderKeepsLock() async throws {
        let mnt = try image(.hfsPlus, sizeMB: 16)
        try file("src/T/x", "X")
        let t = url("src/T")
        lock(t)
        let (tuning, seen) = lockProbe(t)
        let scripted = ScriptedInteraction(errors: [.unlockAndContinue])
        let (queue, _) = makeQueue(interaction: scripted, tuning: tuning)
        let o = try await run(.move(sources: [t], destination: mnt), on: queue)
        let target = mnt.appending(path: "T")
        XCTAssertEqual(text(target.appending(path: "x")), "X")
        XCTAssertTrue(isLocked(target), "lock kept")
        XCTAssertFalse(exists(t))
        XCTAssertEqual(seen.get(), true)
        XCTAssertEqual(partials(mnt), [])
        XCTAssertEqual(o.skipped, [])
    }

    func testCopyReplaceOfLockedFileKeepsLock() async throws {
        let a = try file("src/a", "new"); try file("d/a", "old")
        lock(a)
        let scripted = ScriptedInteraction(conflicts: [.one(.replace)])
        let (queue, _) = makeQueue(interaction: scripted)
        let o = try await run(.copy(sources: [a], destination: url("d")), on: queue)
        XCTAssertEqual(text(url("d/a")), "new")
        XCTAssertTrue(isLocked(url("d/a")), "lock kept")
        XCTAssertTrue(isLocked(a), "source unchanged")
        XCTAssertEqual(scripted.askedErrors().count, 0)
        XCTAssertEqual(partials(url("d")), [])
        XCTAssertEqual(o.skipped, [])
    }
}
