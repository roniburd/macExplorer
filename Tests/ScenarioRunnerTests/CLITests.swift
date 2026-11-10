import XCTest
@testable import macx_scenarios

final class CLITests: XCTestCase {
    func testParsesOptions() throws {
        let o = try ScenarioCLIOptions.parse(["--filter", "ops.", "--json", "/tmp/macx-scenario-x/r.json", "--keep-sandbox", "--require-images", "--list"])
        XCTAssertEqual(o.filter, "ops.")
        XCTAssertEqual(o.json?.lastPathComponent, "r.json")
        XCTAssertTrue(o.keepSandbox && o.requireImages && o.list)
    }

    func testParsesSandboxManifest() throws {
        let o = try ScenarioCLIOptions.parse(["--manifest", "/tmp/macx-scenario-x/sandboxes.txt"])
        XCTAssertEqual(o.manifest?.lastPathComponent, "sandboxes.txt")
        XCTAssertThrowsError(try ScenarioCLIOptions.parse(["--manifest"])) { XCTAssertEqual($0 as? ScenarioCLIError, .missingValue("--manifest")) }
    }

    func testRejectsUnknownOptionsAndMissingValues() {
        XCTAssertThrowsError(try ScenarioCLIOptions.parse(["--nope"])) { XCTAssertEqual($0 as? ScenarioCLIError, .unknownOption("--nope")) }
        XCTAssertThrowsError(try ScenarioCLIOptions.parse(["--filter"])) { XCTAssertEqual($0 as? ScenarioCLIError, .missingValue("--filter")) }
    }

    func testCrashHelperRefusesPathsOutsideScenarioSandboxes() {
        XCTAssertFalse(CrashHelper.isInsideScenarioSandbox("/Library/someone/file.txt"))
        XCTAssertFalse(CrashHelper.isInsideScenarioSandbox("/tmp/other/file"))
        XCTAssertFalse(CrashHelper.isInsideScenarioSandbox("/tmp/macx-scenario-1/../../etc/hosts"))
        XCTAssertFalse(CrashHelper.isInsideScenarioSandbox("relative/macx-scenario-1/a"))
        XCTAssertTrue(CrashHelper.isInsideScenarioSandbox("/private/var/folders/x/T/macx-scenario-1234/work/a.txt"))
    }

    func testCrashHelperOptionParsing() throws {
        let base = "/tmp/macx-scenario-1"
        let o = try CrashHelperOptions.parse(["--mode", "replace", "--source", "\(base)/s", "--destination", "\(base)/d",
                                              "--journal", "\(base)/j.json", "--trash", "\(base)/t", "--ready", "\(base)/r"])
        XCTAssertEqual(o.mode, .replace)
        XCTAssertEqual(o.allPaths.count, 5)
        XCTAssertThrowsError(try CrashHelperOptions.parse(["--mode", "copy"])) { XCTAssertEqual($0 as? ScenarioCLIError, .missingOption("--source")) }
        XCTAssertThrowsError(try CrashHelperOptions.parse(["--mode", "explode"]))
    }

    /// P4-23: batchRename mode renames items of the --source folder (--destination is the same folder) by --names
    /// ("old/new" per line; plain names only) and stops after phase 1.
    func testCrashHelperBatchRenameOptions() throws {
        let base = "/tmp/macx-scenario-1"
        let args = ["--mode", "batchRename", "--source", "\(base)/w", "--destination", "\(base)/w", "--journal", "\(base)/j.json",
                    "--trash", "\(base)/t", "--ready", "\(base)/r"]
        let o = try CrashHelperOptions.parse(args + ["--names", "a.txt/b.txt\nb.txt/a.txt"])
        XCTAssertEqual(o.mode, .batchRename)
        XCTAssertEqual(o.renames.map(\.0), ["a.txt", "b.txt"])
        XCTAssertEqual(o.renames.map(\.1), ["b.txt", "a.txt"])
        XCTAssertThrowsError(try CrashHelperOptions.parse(args)) { XCTAssertEqual($0 as? ScenarioCLIError, .missingOption("--names")) }
        for bad in ["a.txt", "a.txt/../x", "../a/b", "a/", "/b"] {
            XCTAssertThrowsError(try CrashHelperOptions.parse(args + ["--names", bad]), bad)
        }
    }
}
