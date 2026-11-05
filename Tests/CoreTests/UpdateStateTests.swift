import Foundation
import XCTest
@testable import Core

final class UpdateStateTests: XCTestCase {
    private let notes = URL(string: "https://github.com/roniburd/macExplorer/releases/tag/v0.4.0")!

    func testReleaseChannelNeverAllowsBetaItems() {
        XCTAssertEqual(UpdateChannel.release.sparkleChannels, [])
        XCTAssertEqual(UpdateChannel.beta.sparkleChannels, ["beta"])
    }

    func testUserCheckFindsNothing() {
        let s = UpdateState.idle.reduce(.checkStarted(userInitiated: true)).reduce(.noUpdateFound(currentVersion: "0.3.1"))
        XCTAssertEqual(s, .upToDate(version: "0.3.1"))
        XCTAssertTrue(s.isBadgeVisible)
        XCTAssertEqual(s.reduce(.acknowledged), .idle)
    }

    func testBackgroundCheckFindingNothingStaysInvisible() {
        let s = UpdateState.idle.reduce(.checkStarted(userInitiated: false))
        XCTAssertFalse(s.isBadgeVisible)
        XCTAssertEqual(s.reduce(.noUpdateFound(currentVersion: "0.3.1")), .idle)
    }

    func testBackgroundUpdateDownloadsSilentlyThenShowsBadge() {
        var s = UpdateState.idle.reduce(.updateFound(version: "0.4.0"))
        XCTAssertEqual(s, .downloading(version: "0.4.0", fraction: nil, userInitiated: false))
        XCTAssertFalse(s.isBadgeVisible)
        s = s.reduce(.downloadProgress(0.5))
        XCTAssertEqual(s, .downloading(version: "0.4.0", fraction: 0.5, userInitiated: false))
        s = s.reduce(.readyToInstall(version: "0.4.0", notesURL: notes))
        XCTAssertEqual(s, .readyToRestart(version: "0.4.0", notesURL: notes))
        XCTAssertTrue(s.isBadgeVisible)
    }

    func testUserCheckShowsDownloadProgress() {
        let s = UpdateState.idle.reduce(.checkStarted(userInitiated: true)).reduce(.updateFound(version: "0.4.0"))
        XCTAssertEqual(s, .downloading(version: "0.4.0", fraction: nil, userInitiated: true))
        XCTAssertTrue(s.isBadgeVisible)
    }

    func testUserCheckDuringBackgroundDownloadBecomesVisible() {
        let s = UpdateState.downloading(version: "0.4.0", fraction: 0.2, userInitiated: false)
            .reduce(.checkStarted(userInitiated: true))
        XCTAssertEqual(s, .downloading(version: "0.4.0", fraction: 0.2, userInitiated: true))
    }

    func testReadyToRestartIsSticky() {
        let ready = UpdateState.readyToRestart(version: "0.4.0", notesURL: notes)
        for event: UpdateEvent in [.checkStarted(userInitiated: true), .noUpdateFound(currentVersion: "0.3.1"),
                                   .updateFound(version: "0.4.0"), .downloadProgress(0.3), .failed(.offline), .acknowledged] {
            XCTAssertEqual(ready.reduce(event), ready, "\(event)")
        }
        XCTAssertEqual(ready.reduce(.readyToInstall(version: "0.4.1", notesURL: nil)), .readyToRestart(version: "0.4.1", notesURL: nil))
    }

    func testBackgroundFailureIsSilentButVerificationFailureIsShown() {
        XCTAssertEqual(UpdateState.checking(userInitiated: false).reduce(.failed(.offline)), .idle)
        let v = UpdateState.downloading(version: "0.4.0", fraction: nil, userInitiated: false)
            .reduce(.failed(.verificationFailed(version: "0.4.0")))
        XCTAssertEqual(v, .failed(.verificationFailed(version: "0.4.0"), userInitiated: false))
        XCTAssertTrue(v.isBadgeVisible)
        XCTAssertEqual(v.reduce(.acknowledged), .idle)
    }

    func testUserFailureIsShown() {
        let s = UpdateState.checking(userInitiated: true).reduce(.failed(.network("timed out")))
        XCTAssertEqual(s, .failed(.network("timed out"), userInitiated: true))
        XCTAssertTrue(s.isBadgeVisible)
    }

    func testIrrelevantEventsAreIgnored() {
        XCTAssertEqual(UpdateState.idle.reduce(.downloadProgress(0.4)), .idle)
        XCTAssertEqual(UpdateState.idle.reduce(.acknowledged), .idle)
        XCTAssertEqual(UpdateState.upToDate(version: "1").reduce(.downloadProgress(0.4)), .upToDate(version: "1"))
    }

    func testTransitionDistinguishesIllegalFromNoOp() {
        // Illegal events: nil, so the caller can log them (spec §2.1).
        XCTAssertNil(UpdateState.idle.transition(.downloadProgress(0.4)))
        XCTAssertNil(UpdateState.idle.transition(.acknowledged))
        XCTAssertNil(UpdateState.idle.transition(.failed(.verificationFailed(version: "1"))))
        XCTAssertNil(UpdateState.idle.transition(.noUpdateFound(currentVersion: "1")))
        let ready = UpdateState.readyToRestart(version: "2", notesURL: nil)
        XCTAssertNil(ready.transition(.checkStarted(userInitiated: true)))
        XCTAssertNil(ready.transition(.updateFound(version: "3")))
        XCTAssertNil(UpdateState.downloading(version: "2", fraction: 0.1, userInitiated: false).transition(.updateFound(version: "3")))
        // Accepted events whose result equals the current state: non-nil.
        let dl = UpdateState.downloading(version: "2", fraction: 0.5, userInitiated: false)
        XCTAssertEqual(dl.transition(.downloadProgress(0.5)), dl)
        XCTAssertEqual(UpdateState.checking(userInitiated: true).transition(.checkStarted(userInitiated: false)), .checking(userInitiated: true))
        XCTAssertEqual(ready.transition(.readyToInstall(version: "2", notesURL: nil)), ready)
        // reduce agrees with transition.
        XCTAssertEqual(UpdateState.idle.reduce(.acknowledged), .idle)
        XCTAssertEqual(UpdateState.idle.reduce(.updateFound(version: "2")), UpdateState.idle.transition(.updateFound(version: "2")))
    }

    @MainActor func testSettingsDefaultsAndPersistence() {
        let storage = InMemorySettingsStorage()
        let s = Settings(storage: storage, home: URL(filePath: "/tmp/macx-tests-home", directoryHint: .isDirectory))
        XCTAssertEqual(s.updateChannel, .release)
        XCTAssertTrue(s.checkForUpdatesAutomatically)
        XCTAssertTrue(s.offerToReportCrashes)
        XCTAssertEqual(s.lastReportedCrashes, [])
        s.updateChannel = .beta
        s.checkForUpdatesAutomatically = false
        s.offerToReportCrashes = false
        for i in 0..<25 { s.markCrashReported("macExplorer-\(i).ips") }
        // Re-mark a name that is still in the list (24…5 are kept), so the dedupe actually runs.
        s.markCrashReported("macExplorer-10.ips")
        let reloaded = Settings(storage: storage, home: s.home)
        XCTAssertEqual(reloaded.updateChannel, .beta)
        XCTAssertFalse(reloaded.checkForUpdatesAutomatically)
        XCTAssertFalse(reloaded.offerToReportCrashes)
        XCTAssertEqual(reloaded.lastReportedCrashes.count, Settings.lastReportedCrashesLimit)
        XCTAssertEqual(reloaded.lastReportedCrashes.first, "macExplorer-10.ips")
        XCTAssertEqual(reloaded.lastReportedCrashes.filter { $0 == "macExplorer-10.ips" }.count, 1)
        XCTAssertEqual(Set(reloaded.lastReportedCrashes).count, reloaded.lastReportedCrashes.count)
        XCTAssertEqual(reloaded.lastReportedCrashes.dropFirst().first, "macExplorer-24.ips")
        XCTAssertEqual(reloaded.lastReportedCrashes.last, "macExplorer-5.ips")
    }

    @MainActor func testLastReportedCrashesAreClampedOnLoad() throws {
        let storage = InMemorySettingsStorage()
        let names = (0..<30).map { "macExplorer-\($0).ips" }
        storage.set(try JSONEncoder().encode(names), forKey: "lastReportedCrashes")
        let s = Settings(storage: storage, home: URL(filePath: "/tmp/macx-tests-home", directoryHint: .isDirectory))
        XCTAssertEqual(s.lastReportedCrashes, Array(names.prefix(Settings.lastReportedCrashesLimit)))
    }
}
