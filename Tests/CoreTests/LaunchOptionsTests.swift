import XCTest
@testable import Core
import MacxFS

final class LaunchOptionsTests: XCTestCase {
    private func dir(_ path: String) -> URL { URL(filePath: path, directoryHint: .isDirectory) }

    func testNoArgumentsGivesDefaults() throws {
        let o = try LaunchOptions.parse(["macExplorer"])
        XCTAssertEqual(o, LaunchOptions())
        XCTAssertNil(o.root)
        XCTAssertNil(o.stateDirectory)
        XCTAssertNil(o.sandboxTrash)
        XCTAssertNil(o.pasteboardName)
        XCTAssertFalse(o.fakeLaunchServices)
        XCTAssertFalse(o.skipOnboarding)
        XCTAssertNil(o.scenario)
        XCTAssertNil(o.scenarioOutput)
        XCTAssertNil(o.smokeExitAfter)
        XCTAssertFalse(o.isSandboxed)
    }

    func testEmptyArgumentVectorIsAccepted() throws {
        XCTAssertEqual(try LaunchOptions.parse([]), LaunchOptions())
    }

    func testFullSandboxCommandLine() throws {
        let o = try LaunchOptions.parse([
            "/path/to/macExplorer",
            "--root", "/tmp/macx-scenario-x/files",
            "--state-dir", "/tmp/macx-scenario-x/state",
            "--sandbox-trash", "/tmp/macx-scenario-x/.trash",
            "--pasteboard", "macx-tests-1234",
            "--fake-launch-services",
            "--skip-onboarding",
            "--scenario", "/tmp/macx-scenario-x/s.json",
            "--scenario-output", "/tmp/macx-scenario-x/out.json",
            "--smoke-exit-after", "1.5",
        ])
        XCTAssertEqual(o.root, dir("/tmp/macx-scenario-x/files"))
        XCTAssertEqual(o.stateDirectory, dir("/tmp/macx-scenario-x/state"))
        XCTAssertEqual(o.sandboxTrash, dir("/tmp/macx-scenario-x/.trash"))
        XCTAssertEqual(o.pasteboardName, "macx-tests-1234")
        XCTAssertTrue(o.fakeLaunchServices)
        XCTAssertTrue(o.skipOnboarding)
        XCTAssertEqual(o.scenario, URL(filePath: "/tmp/macx-scenario-x/s.json", directoryHint: .notDirectory))
        XCTAssertEqual(o.scenarioOutput, URL(filePath: "/tmp/macx-scenario-x/out.json", directoryHint: .notDirectory))
        XCTAssertEqual(o.smokeExitAfter, .milliseconds(1500))
        XCTAssertTrue(o.isSandboxed)
    }

    func testDirectoryOptionsAreDirectoryURLs() throws {
        let o = try LaunchOptions.parse(["macExplorer", "--root", "/tmp/a", "--state-dir", "/tmp/a/state/"])
        XCTAssertTrue(o.root?.hasDirectoryPath ?? false)
        XCTAssertTrue(o.stateDirectory?.hasDirectoryPath ?? false)
        XCTAssertEqual(o.root?.path(percentEncoded: false), "/tmp/a/")
        XCTAssertEqual(o.stateDirectory?.path(percentEncoded: false), "/tmp/a/state/")
    }

    func testPathsAreStandardized() throws {
        let o = try LaunchOptions.parse(["macExplorer", "--root", "/tmp/a/./b/../c", "--state-dir", "/tmp/s"])
        XCTAssertEqual(o.root, dir("/tmp/a/c"))
    }

    func testRelativePathsResolveAgainstCurrentDirectory() throws {
        let o = try LaunchOptions.parse(["macExplorer", "--root", "rel/dir", "--state-dir", "/tmp/s"])
        let cwd = FileManager.default.currentDirectoryPath
        XCTAssertEqual(o.root?.path(percentEncoded: false),
                       URL(filePath: cwd, directoryHint: .isDirectory).appending(path: "rel/dir/").standardized.path(percentEncoded: false))
        XCTAssertNil(o.root?.baseURL, "absolute, no base URL")
    }

    func testRootMatchesSandboxStyleURL() throws {
        // Later tasks compare options.root against URL(filePath:directoryHint: .isDirectory) values.
        let path = "/private/var/folders/xy/T/macx-tests-ABC/"
        let o = try LaunchOptions.parse(["macExplorer", "--root", path, "--state-dir", path + "state"])
        XCTAssertEqual(o.root, URL(filePath: path, directoryHint: .isDirectory))
    }

    func testStateDirectoryAloneIsSandboxed() throws {
        let o = try LaunchOptions.parse(["macExplorer", "--state-dir", "/tmp/s"])
        XCTAssertTrue(o.isSandboxed)
        XCTAssertNil(o.root)
    }

    func testRootWithoutStateDirIsRejected() {
        XCTAssertThrowsError(try LaunchOptions.parse(["macExplorer", "--root", "/tmp/a"])) {
            XCTAssertEqual($0 as? LaunchOptionsError, .stateDirectoryRequired)
        }
    }

    func testScenarioWithoutStateDirIsRejected() {
        XCTAssertThrowsError(try LaunchOptions.parse(["macExplorer", "--scenario", "/tmp/s.json"])) {
            XCTAssertEqual($0 as? LaunchOptionsError, .stateDirectoryRequired)
        }
    }

    func testSmokeExitWithoutStateDirIsRejected() {
        // smoke.json is written into the state directory, so smoke runs are always sandboxed.
        XCTAssertThrowsError(try LaunchOptions.parse(["macExplorer", "--smoke-exit-after", "1"])) {
            XCTAssertEqual($0 as? LaunchOptionsError, .stateDirectoryRequired)
        }
    }

    func testMissingValues() {
        for option in ["--root", "--state-dir", "--sandbox-trash", "--pasteboard", "--scenario", "--scenario-output", "--smoke-exit-after"] {
            XCTAssertThrowsError(try LaunchOptions.parse(["macExplorer", option]), option) {
                XCTAssertEqual($0 as? LaunchOptionsError, .missingValue(option))
            }
            XCTAssertThrowsError(try LaunchOptions.parse(["macExplorer", option, "--skip-onboarding"]), option) {
                XCTAssertEqual($0 as? LaunchOptionsError, .missingValue(option), "another option is not a value")
            }
            XCTAssertThrowsError(try LaunchOptions.parse(["macExplorer", option, ""]), option) {
                XCTAssertEqual($0 as? LaunchOptionsError, .missingValue(option), "empty value")
            }
        }
    }

    func testInvalidSmokeDurationIsMissingValue() {
        for bad in ["abc", "-1", "nan", "inf"] {
            XCTAssertThrowsError(try LaunchOptions.parse(["macExplorer", "--state-dir", "/tmp/s", "--smoke-exit-after", bad]), bad) {
                XCTAssertEqual($0 as? LaunchOptionsError, .missingValue("--smoke-exit-after"))
            }
        }
    }

    func testSmokeDurationAcceptsZeroAndIntegers() throws {
        XCTAssertEqual(try LaunchOptions.parse(["m", "--state-dir", "/tmp/s", "--smoke-exit-after", "0"]).smokeExitAfter, .zero)
        XCTAssertEqual(try LaunchOptions.parse(["m", "--state-dir", "/tmp/s", "--smoke-exit-after", "2"]).smokeExitAfter, .seconds(2))
    }

    func testUnknownOptionsAndPositionalArgumentsAreRejected() {
        XCTAssertThrowsError(try LaunchOptions.parse(["macExplorer", "--bogus"])) {
            XCTAssertEqual($0 as? LaunchOptionsError, .unknownOption("--bogus"))
        }
        XCTAssertThrowsError(try LaunchOptions.parse(["macExplorer", "stray"])) {
            XCTAssertEqual($0 as? LaunchOptionsError, .unknownOption("stray"))
        }
    }

    func testAppKitDefaultsPairsAreIgnored() throws {
        let o = try LaunchOptions.parse([
            "macExplorer",
            "-ApplePersistenceIgnoreState", "YES",
            "--skip-onboarding",
            "-NSDocumentRevisionsDebugMode", "YES",
            "-AppleLanguages", "(en)",
        ])
        var expected = LaunchOptions()
        expected.skipOnboarding = true
        XCTAssertEqual(o, expected)
    }

    func testTrailingAppKitDefaultWithoutValueIsIgnored() throws {
        XCTAssertEqual(try LaunchOptions.parse(["macExplorer", "-NSQuitAlwaysKeepsWindows"]), LaunchOptions())
    }

    func testProcessSerialNumberArgumentIsIgnored() throws {
        XCTAssertEqual(try LaunchOptions.parse(["macExplorer", "-psn_0_123456"]), LaunchOptions())
    }

    func testLaterValueWins() throws {
        let o = try LaunchOptions.parse(["m", "--pasteboard", "a", "--pasteboard", "b"])
        XCTAssertEqual(o.pasteboardName, "b")
    }

    func testDirectoryOptionPointingAtAFileIsRejected() throws {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "macx-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: tmp) }
        let file = tmp.appending(path: "plain.txt")
        try Data("x".utf8).write(to: file)
        let path = file.path(percentEncoded: false)

        for option in ["--root", "--state-dir", "--sandbox-trash"] {
            var args = ["macExplorer", "--state-dir", tmp.path(percentEncoded: false)]
            args += [option, path]
            XCTAssertThrowsError(try LaunchOptions.parse(args), option) {
                XCTAssertEqual($0 as? LaunchOptionsError, .notADirectory(path))
            }
        }
        // Existing directories and not-yet-existing paths are fine (the app creates the state dir).
        let ok = try LaunchOptions.parse(["m", "--root", tmp.path(percentEncoded: false),
                                          "--state-dir", tmp.appending(path: "state-not-yet").path(percentEncoded: false)])
        XCTAssertEqual(ok.root, URL(filePath: tmp.path(percentEncoded: false), directoryHint: .isDirectory))
    }

    func testErrorsAreEquatableAndDistinct() {
        XCTAssertNotEqual(LaunchOptionsError.missingValue("--root"), .missingValue("--state-dir"))
        XCTAssertNotEqual(LaunchOptionsError.unknownOption("--x"), .notADirectory("--x"))
    }

    func testOptionsAreSendable() {
        let o = LaunchOptions()
        let check: @Sendable () -> LaunchOptions = { o }
        XCTAssertEqual(check(), o)
    }
    func testIndexStatusOption() throws {
        let o = try LaunchOptions.parse(["macExplorer", "--root", "/tmp/macx-scenario-x", "--state-dir", "/tmp/macx-scenario-x/state",
                                         "--index-status", "enabled"])
        XCTAssertEqual(o.indexStatus, .enabled)
        XCTAssertNil(try LaunchOptions.parse(["macExplorer"]).indexStatus)
        XCTAssertThrowsError(try LaunchOptions.parse(["macExplorer", "--index-status", "maybe"])) {
            XCTAssertEqual($0 as? LaunchOptionsError, .invalidValue(option: "--index-status", value: "maybe"))
        }
        XCTAssertThrowsError(try LaunchOptions.parse(["macExplorer", "--index-status"])) {
            XCTAssertEqual($0 as? LaunchOptionsError, .missingValue("--index-status"))
        }
    }

    /// A sandboxed launch's fake index reports --index-status (default disabled); it never asks mdutil.
    func testIndexStatusReachesTheFakeSearchServices() async throws {
        let lanes = LanePool()
        let slash = URL(filePath: "/", directoryHint: .isDirectory)
        for (args, expected) in [([], IndexingStatus.disabled), (["--index-status", "enabled"], .enabled),
                                 (["--index-status", "unknown"], .unknown)] {
            let o = try LaunchOptions.parse(["macExplorer", "--state-dir", "/tmp/macx-scenario-x/state"] + args)
            let services = SearchServices.forLaunch(o, lanes: lanes)
            XCTAssertTrue(services.indexStatus is FixedIndexStatus, "\(args)")
            let status = await services.indexStatus.status(ofVolumeAt: slash)
            XCTAssertEqual(status, expected, "\(args)")
        }
    }
}
