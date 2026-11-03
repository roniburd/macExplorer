import XCTest
import Darwin
@testable import Core
import MacxFS

/// §6.5 rows exercised for real (images created inside the sandbox).
final class ErrorTableTests: FileOpsTestCase {
    func testCopyOntoReadOnlyImageReportsReadOnlyVolume() async throws {
        let mnt = try image(.hfsPlus, sizeMB: 16, readOnly: true)
        let a = try file("a.txt", "A")
        let scripted = ScriptedInteraction(errors: [.cancel], space: [true])
        let (queue, _) = makeQueue(interaction: scripted)
        let o = try await run(.copy(sources: [a], destination: mnt), on: queue)
        XCTAssertEqual(scripted.askedErrors().first?.kind, .readOnlyVolume)
        XCTAssertEqual(FileOpErrorKind.readOnlyVolume.allowedResolutions, [.cancel])
        XCTAssertTrue(o.wasCancelled)
    }

    func testLockedSourceMoveOffersUnlockAndContinue() async throws {
        let a = try file("src/a.txt", "A")
        XCTAssertEqual(lchflags(a.path, UInt32(UF_IMMUTABLE)), 0)
        let scripted = ScriptedInteraction(errors: [.unlockAndContinue])
        let (queue, _) = makeQueue(interaction: scripted)
        _ = try await run(.move(sources: [a], destination: try dir("d")), on: queue)
        XCTAssertEqual(scripted.askedErrors().map(\.kind), [.locked])
        XCTAssertEqual(FileOpErrorKind.locked.allowedResolutions, [.unlockAndContinue, .skip, .cancel])
        XCTAssertEqual(text(url("d/a.txt")), "A")
    }

    func testENOSPCOnSmallImageLeavesNoPartialFile() async throws {
        let mnt = try image(.hfsPlus, sizeMB: 8)
        let big = try bigFile("big", bytes: 24 << 20)
        let scripted = ScriptedInteraction(errors: [.cancel], space: [true])     // Continue Anyway, then Cancel
        let (queue, _) = makeQueue(interaction: scripted)
        let o = try await run(.copy(sources: [big], destination: mnt), on: queue)
        XCTAssertEqual(scripted.askedSpace().count, 1)
        guard case .noSpace? = scripted.askedErrors().first?.kind else { return XCTFail("\(scripted.askedErrors())") }
        XCTAssertEqual(scripted.askedErrors().first?.kind.allowedResolutions, [.retry, .cancel])
        XCTAssertFalse(names(mnt).contains("big"), "half-written file removed")
        XCTAssertTrue(o.wasCancelled)
    }

    func testDeepDestinationReportsNameTooLongAndSkipsOnlyThatItem() async throws {
        let deep = try dir([String(repeating: "x", count: 200), String(repeating: "y", count: 200),
                            String(repeating: "z", count: 200), String(repeating: "w", count: 200)].joined(separator: "/"))
        try file("T/short", "S")
        try file("T/" + String(repeating: "c", count: 200), "C")
        guard deep.path.utf8.count + 3 + 200 > Int(PATH_MAX) else { throw XCTSkip("sandbox path too short to exceed PATH_MAX") }
        let scripted = ScriptedInteraction(errors: [.skip])
        var tuning = FileOpTuning(); tuning.allowClone = false
        let (queue, _) = makeQueue(interaction: scripted, tuning: tuning)
        let o = try await run(.copy(sources: [url("T")], destination: deep), on: queue)
        XCTAssertEqual(scripted.askedErrors().map(\.kind), [.nameTooLong])
        XCTAssertEqual(FileOpErrorKind.nameTooLong.allowedResolutions, [.skip, .cancel])
        XCTAssertEqual(names(deep.appending(path: "T")), ["short"])
        XCTAssertEqual(o.skipped.count, 1)
    }

    func testPermissionDeniedSkipAllAppliesToTheRest() async throws {
        let files = try ["a", "b", "c"].map { try file("src/\($0)") }
        let d = try dir("d")
        XCTAssertEqual(chmod(d.path, 0o555), 0)
        let scripted = ScriptedInteraction(errors: [.skipAll])
        var tuning = FileOpTuning(); tuning.allowClone = false
        let (queue, _) = makeQueue(interaction: scripted, tuning: tuning)
        let o = try await run(.copy(sources: files, destination: d), on: queue)
        XCTAssertEqual(scripted.askedErrors().map(\.kind), [.permissionDenied], "asked once")
        XCTAssertEqual(o.skipped.count, 3)
        XCTAssertFalse(o.wasCancelled, "an error affects only its own item")
    }
}
