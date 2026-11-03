@testable import Core
import Foundation
import MacxFixtures
import MacxFS
import XCTest

/// Single blocking system calls (LaunchServices, bookmark resolution) on synthetic lane volumes: a slow call that
/// does return must not leave the synthetic volume unresponsive for the rest of the app's life.
final class SyntheticLaneTests: XCTestCase {
    private func pool() -> LanePool {
        LanePool(config: WatchdogConfig(stallTimeout: .milliseconds(100), tick: .milliseconds(20), lanesPerClass: 2, poisonCap: 1))
    }

    private let lane = VolumeID(raw: "system:test-synthetic")

    func testPlainPerformLeavesASlowSyntheticVolumeUnresponsive() async throws {
        let lanes = pool()
        _ = try await lanes.perform(on: lane) { _ in Thread.sleep(forTimeInterval: 0.4); return 1 }
        let health = await lanes.health(of: lane)
        XCTAssertEqual(health, .unresponsive, "control: this is the failure mode being fixed")
    }

    func testRecoveringPerformResetsAfterALateReturn() async throws {
        let lanes = pool()
        let slow = try await lanes.performRecovering(on: lane) { _ in Thread.sleep(forTimeInterval: 0.4); return 1 }
        XCTAssertEqual(slow, 1)
        let deadline = ContinuousClock.now + .seconds(2)
        while await lanes.health(of: lane) != .healthy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let health = await lanes.health(of: lane)
        XCTAssertEqual(health, .healthy)
        let fast = try await lanes.performRecovering(on: lane) { _ in 2 }
        XCTAssertEqual(fast, 2, "later lookups still run")
    }

    func testLaunchServicesLookupsRecover() async throws {
        let lanes = pool()
        _ = try await lanes.performRecovering(on: WorkspaceLaunchServices.lane) { _ in Thread.sleep(forTimeInterval: 0.4); return 0 }
        try await Task.sleep(for: .milliseconds(100))
        let ls = WorkspaceLaunchServices(lanes: lanes)
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }
        let app = await ls.appInfo(at: URL(filePath: "/System/Applications/TextEdit.app", directoryHint: .isDirectory))
        let missing = await ls.appInfo(at: sandbox.url("none.app"))
        XCTAssertNotNil(app, "the lane volume is usable after a slow lookup returned")
        XCTAssertNil(missing)
    }

    func testFavoritesRouteToTheVolumeOfTheirLastKnownPath() {
        let vol = VolumeInfo(id: VolumeID(raw: "share"), mountPoint: URL(filePath: "/Volumes/Share", directoryHint: .isDirectory),
                             name: "Share", format: "smbfs", isBoot: false, isInternal: false, isRemovable: false,
                             isEjectable: true, isLocal: false, isReadOnly: false, isBrowsable: true, totalCapacity: nil,
                             capabilities: VolumeCapabilities(idStable: false, renameExcl: false, clone: false, caseSensitive: false))
        let table = MountTable([vol])
        let onShare = Favorite(bookmark: Data(), displayName: "P", lastKnownPath: "/Volumes/Share/Projects")
        let elsewhere = Favorite(bookmark: Data(), displayName: "D", lastKnownPath: "/Users/u/Docs")
        XCTAssertEqual(FavoritesResolver.lane(for: onShare, in: table), VolumeID(raw: "share"))
        XCTAssertEqual(FavoritesResolver.lane(for: elsewhere, in: table), .unknown)
        XCTAssertEqual(FavoritesResolver.lane(for: onShare, in: .empty), .unknown)
    }
}
