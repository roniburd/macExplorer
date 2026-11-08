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

    /// Polls until `condition` holds; fails loudly (rather than letting a later assertion fail confusingly) after a
    /// deadline generous enough for a starved CI runner.
    private func eventually(_ what: String, timeout: Duration = .seconds(30),
                            _ condition: () async -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !(await condition()) {
            if ContinuousClock.now > deadline { return XCTFail("timed out waiting for \(what)") }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The slow call: it blocks until the test has seen the watchdog declare the stall (with poisonCap 1 that marks
    /// `volume` unresponsive), then returns late. Ordering by observation, not by a sleep racing the watchdog tick.
    private func returnLateAfterTheStall(
        on lanes: LanePool, _ volume: VolumeID,
        _ call: @escaping @Sendable (@escaping @Sendable (LaneContext) throws -> Int) async throws -> Int
    ) async throws -> Int {
        let release = DispatchSemaphore(value: 0)
        let slow = Task { try await call { _ in _ = release.wait(timeout: .now() + 60); return 1 } }
        await eventually("the watchdog to declare the slow call stalled") { await lanes.health(of: volume) == .unresponsive }
        release.signal()
        return try await slow.value
    }

    func testPlainPerformLeavesASlowSyntheticVolumeUnresponsive() async throws {
        let lanes = pool(), volume = lane
        let slow = try await returnLateAfterTheStall(on: lanes, volume) { work in try await lanes.perform(on: volume, .read, work) }
        XCTAssertEqual(slow, 1)
        let health = await lanes.health(of: volume)
        XCTAssertEqual(health, .unresponsive, "control: this is the failure mode being fixed")
    }

    func testRecoveringPerformResetsAfterALateReturn() async throws {
        let lanes = pool(), volume = lane
        let slow = try await returnLateAfterTheStall(on: lanes, volume) { work in
            try await lanes.performRecovering(on: volume, .read, work)
        }
        XCTAssertEqual(slow, 1)
        let health = await lanes.health(of: volume)
        XCTAssertEqual(health, .healthy, "reset as soon as the stalled call returned")
        let fast = try await lanes.performRecovering(on: volume) { _ in 2 }
        XCTAssertEqual(fast, 2, "later lookups still run")
    }

    func testLaunchServicesLookupsRecover() async throws {
        let lanes = pool(), volume = WorkspaceLaunchServices.lane
        _ = try await returnLateAfterTheStall(on: lanes, volume) { work in try await lanes.performRecovering(on: volume, .read, work) }
        let health = await lanes.health(of: volume)
        XCTAssertEqual(health, .healthy)
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
