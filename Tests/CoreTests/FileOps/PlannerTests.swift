import XCTest
import Darwin
@testable import Core
import MacxFS

final class PlannerTests: FileOpsTestCase {
    private func plan(_ sources: [URL], _ dest: URL?, _ mode: PlanMode, force: Bool = false) async throws -> JobPlan {
        try await LanePool().perform(on: .unknown, .fileOp) { lane in
            Planner.plan(sources: sources, destination: dest, mode: mode, forceCrossVolume: force, lane: lane)
        }
    }

    func testPlanCountsItemsAndBytes() async throws {
        try file("a/f1", String(repeating: "1", count: 10))
        try file("a/sub/f2", String(repeating: "2", count: 20))
        let p = try await plan([url("a")], try dir("d"), .copy)
        XCTAssertEqual(p.items.count, 1)
        XCTAssertEqual(p.items[0].entries.map(\.relativePath), ["", "f1", "sub", "sub/f2"])
        XCTAssertEqual(p.totalItems, 4)
        XCTAssertEqual(p.totalBytes, 30)
        XCTAssertEqual(p.items[0].entries.first?.type, .directory)
    }

    func testPlanReportsMissingSourceAsSourceGone() async throws {
        let p = try await plan([url("missing"), try file("x")], try dir("d"), .copy)
        XCTAssertEqual(p.refused, [Refusal(url: url("missing"), kind: .sourceGone)])
        XCTAssertEqual(p.items.map(\.source), [url("x")])
    }

    /// Review Focus 1 (mandatory name).
    func testPlanRefusesCopyAndMoveIntoSelfOrDescendant() async throws {
        let a = try dir("A/sub")
        let b = try file("B")
        XCTAssertEqual(symlink(url("A").path, url("L").path), 0)       // destination reached through a link
        for mode in [PlanMode.copy, .move] {
            for dest in [a, url("A"), url("L/sub")] {
                let p = try await plan([url("A"), b], dest, mode)
                XCTAssertEqual(p.refused, [Refusal(url: url("A"), kind: .intoItself)], "\(mode) into \(dest.path)")
                XCTAssertEqual(p.items.map(\.source), [b])
            }
        }
        XCTAssertTrue(Planner.isSelfOrDescendant(source: "/x/A", destination: "/x/A"))
        XCTAssertTrue(Planner.isSelfOrDescendant(source: "/x/A", destination: "/x/A/b/c"))
        XCTAssertFalse(Planner.isSelfOrDescendant(source: "/x/A", destination: "/x/AB"))
        XCTAssertFalse(Planner.isSelfOrDescendant(source: "/x/A", destination: "/x"))
    }

    func testPlanNeverFollowsSymlinks() async throws {
        try bigFile("elsewhere/huge", bytes: 1 << 20)
        try dir("a")
        XCTAssertEqual(symlink("../elsewhere", url("a/link").path), 0)
        XCTAssertEqual(symlink(".", url("a/self").path), 0)
        let p = try await plan([url("a")], try dir("d"), .copy)
        XCTAssertEqual(Set(p.items[0].entries.map(\.relativePath)), ["", "link", "self"])
        XCTAssertEqual(p.items[0].entries.filter { $0.type == .symlink }.count, 2)
        XCTAssertEqual(p.totalBytes, 0)
    }

    func testSameVolumeMoveIsShallowAndNeedsNoSpace() async throws {
        try file("a/f1"); try file("a/f2")
        let p = try await plan([url("a")], try dir("d"), .move)
        XCTAssertTrue(p.items[0].sameVolume)
        XCTAssertEqual(p.items[0].entries.count, 1)
        XCTAssertEqual(p.neededBytes, 0)
    }

    func testForcedCrossVolumeMoveEnumeratesAndCountsSpace() async throws {
        try bigFile("a/f1", bytes: 64 << 10)
        let p = try await plan([url("a")], try dir("d"), .move, force: true)
        XCTAssertFalse(p.items[0].sameVolume)
        XCTAssertEqual(p.items[0].entries.count, 2)
        XCTAssertGreaterThanOrEqual(p.neededBytes, 64 << 10)
    }

    func testCopyNeedsNoSpaceWhenDestinationClones() async throws {
        try bigFile("f", bytes: 1 << 20)
        let p = try await plan([url("f")], try dir("d"), .copy)
        guard p.capabilities.clone else { throw XCTSkip("sandbox volume does not clone") }
        XCTAssertEqual(p.neededBytes, 0)
    }

    func testTopLevelConflictsAreDetected() async throws {
        try file("src/a"); try file("src/b"); try file("d/a")
        let p = try await plan([url("src/a"), url("src/b")], url("d"), .copy)
        XCTAssertEqual(p.topLevelConflicts, [url("src/a")])
    }

    func testEnumerateWithNoMaterializationMatchesDefault() async throws {
        try file("t/x"); try file("t/y/z")
        let lanes = LanePool()
        let t = url("t")
        let (withPolicy, plain) = try await lanes.perform(on: .unknown, .fileOp) { lane in
            let info = PosixFS.info(t.path)!
            return (Planner.enumerate(t, info: info, noMaterialization: true, lane: lane).entries,
                    Planner.enumerate(t, info: info, noMaterialization: false, lane: lane).entries)
        }
        XCTAssertEqual(withPolicy, plain)
    }

    func testVolumeIdentityUsesDeviceNotPrefix() async throws {
        let mnt = try image(.hfsPlus, sizeMB: 16)
        let a = try file("a")
        let sandboxRoot = root
        let same = try await LanePool().perform(on: .unknown, .fileOp) { _ in
            (VolumeIdentity.isSameVolume(a, destinationDirectory: sandboxRoot),
             VolumeIdentity.isSameVolume(a, destinationDirectory: mnt))
        }
        XCTAssertTrue(same.0)
        XCTAssertFalse(same.1, "the image is mounted under the sandbox path but is another device")
    }
}
