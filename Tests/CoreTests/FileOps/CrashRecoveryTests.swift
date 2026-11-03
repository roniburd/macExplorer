import XCTest
import Darwin
@testable import Core
import MacxFS

final class CrashRecoveryTests: FileOpsTestCase {
    private func spec(_ sources: [URL], _ dest: URL, fault: FaultPoint, mode: String = "move",
                      conflict: ConflictAction? = nil, force: Bool) -> CrashSpec {
        CrashSpec(mode: mode, sources: sources.map(\.path), destination: dest.path, journal: journalURL.path,
                  trash: trashDir.path, fault: fault.rawValue, conflict: conflict?.rawValue,
                  forceCrossVolume: force, allowClone: false)
    }

    func testKillDuringCrossVolumeCopyKeepsSourceAndRecoveryRemovesPartial() async throws {
        try bigFile("src/T/big", bytes: 32 << 20); try file("src/T/small", "S")
        let before = try Data(contentsOf: url("src/T/big"))
        let d = try dir("d")
        let killed = try await runCrashingChild(spec([url("src/T")], d, fault: .midCopyChunk, force: true))
        XCTAssertTrue(killed)
        XCTAssertEqual(names(d).filter { PartialName.isPartial($0) }.count, 1, "partial left by the crash: \(names(d))")
        XCTAssertEqual(try Data(contentsOf: url("src/T/big")), before)
        let journal = Journal(fileURL: journalURL)
        let report = await LaunchRecovery.run(journal: journal, lanes: LanePool())
        XCTAssertEqual(report.removedPartials.count, 1)
        XCTAssertEqual(report.incompleteJobs.count, 1)
        XCTAssertEqual(names(d), [])
        XCTAssertEqual(names(url("src/T")), ["big", "small"])
        let left = await journal.entries()
        XCTAssertEqual(left, [])
    }

    func testKillDuringMoveToDiskImageKeepsSource() async throws {
        let mnt = try image(.hfsPlus, sizeMB: 64)
        try bigFile("src/big", bytes: 24 << 20)
        let killed = try await runCrashingChild(spec([url("src/big")], mnt, fault: .midCopyChunk, force: false))
        XCTAssertTrue(killed)
        XCTAssertEqual(lst(url("src/big")).st_size, 24 << 20)
        let report = await LaunchRecovery.run(journal: Journal(fileURL: journalURL), lanes: LanePool())
        XCTAssertEqual(report.removedPartials.count, 1)
        XCTAssertFalse(names(mnt).contains { PartialName.isPartial($0) || $0 == "big" })
    }

    func testKillBeforeSourceDeleteLosesNothing() async throws {
        try file("src/T/a", "A")
        let d = try dir("d")
        let killed = try await runCrashingChild(spec([url("src/T")], d, fault: .beforeSourceDelete, force: true))
        XCTAssertTrue(killed)
        XCTAssertEqual(text(url("d/T/a")), "A")
        XCTAssertEqual(text(url("src/T/a")), "A")
        let report = await LaunchRecovery.run(journal: Journal(fileURL: journalURL), lanes: LanePool())
        XCTAssertEqual(report.removedPartials, [])
        XCTAssertEqual(report.incompleteJobs.count, 1)
        XCTAssertEqual(text(url("d/T/a")), "A")
        XCTAssertEqual(text(url("src/T/a")), "A")
    }

    func testKillAfterPartialCopyRecoveryRemovesCompletePartial() async throws {
        try file("src/f", "F")
        let d = try dir("d")
        let killed = try await runCrashingChild(spec([url("src/f")], d, fault: .afterPartialCopy, force: true))
        XCTAssertTrue(killed)
        let report = await LaunchRecovery.run(journal: Journal(fileURL: journalURL), lanes: LanePool())
        XCTAssertEqual(report.removedPartials.map { PartialName.isPartial($0.lastPathComponent) }, [true])
        XCTAssertEqual(names(d), [])
        XCTAssertEqual(text(url("src/f")), "F")
    }

    func testKillAfterTrashingDestinationRestoresIt() async throws {
        try file("src/a", "new"); try file("d/a", "old")
        let d = url("d")
        let killed = try await runCrashingChild(spec([url("src/a")], d, fault: .afterTrashDestination, conflict: .replace, force: true))
        XCTAssertTrue(killed)
        XCTAssertFalse(exists(url("d/a")), "destination was in the trash at the moment of the kill")
        let report = await LaunchRecovery.run(journal: Journal(fileURL: journalURL), lanes: LanePool())
        XCTAssertEqual(report.restoredDestinations, [url("d/a")])
        XCTAssertEqual(report.removedPartials.count, 1)
        XCTAssertEqual(text(url("d/a")), "old")
        XCTAssertEqual(text(url("src/a")), "new")
        XCTAssertEqual(names(d), ["a"])
    }
}
