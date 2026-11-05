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
        s.markCrashReported("macExplorer-3.ips")
        let reloaded = Settings(storage: storage, home: s.home)
        XCTAssertEqual(reloaded.updateChannel, .beta)
        XCTAssertFalse(reloaded.checkForUpdatesAutomatically)
        XCTAssertFalse(reloaded.offerToReportCrashes)
        XCTAssertEqual(reloaded.lastReportedCrashes.count, Settings.lastReportedCrashesLimit)
        XCTAssertEqual(reloaded.lastReportedCrashes.first, "macExplorer-3.ips")
        XCTAssertEqual(reloaded.lastReportedCrashes.filter { $0 == "macExplorer-3.ips" }.count, 1)
    }
}
