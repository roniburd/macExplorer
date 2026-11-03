import AppKit
import XCTest
import UI

/// Launches the built `macExplorer` executable (unbundled, from the build products directory) against a fresh
/// sandbox under $TMPDIR. Never points the app at a real user folder.
final class AppSmokeTests: XCTestCase {
    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory.appending(path: "macx-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: false)
        addTeardownBlock { [sandbox] in if let sandbox { try? FileManager.default.removeItem(at: sandbox) } }
    }

    private func executable() throws -> URL {
        let products = Bundle(for: AppSmokeTests.self).bundleURL.deletingLastPathComponent()
        let exe = products.appending(path: "macExplorer", directoryHint: .notDirectory)
        guard FileManager.default.isExecutableFile(atPath: exe.path(percentEncoded: false)) else {
            throw XCTSkip("macExplorer executable not built next to the test bundle (\(products.path(percentEncoded: false)))")
        }
        return exe
    }

    private func run(_ arguments: [String], timeout: TimeInterval = 60) throws -> (status: Int32, stderr: String) {
        let process = Process()
        process.executableURL = try executable()
        process.arguments = arguments
        process.currentDirectoryURL = sandbox
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice
        let done = expectation(description: "exit")
        process.terminationHandler = { _ in done.fulfill() }
        try process.run()
        let result = XCTWaiter.wait(for: [done], timeout: timeout)
        if result != .completed {
            process.terminate()
            XCTFail("macExplorer did not exit within \(timeout) s")
        }
        process.waitUntilExit()
        let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus, err)
    }

    private func sandboxArguments(root: URL, state: URL) -> [String] {
        ["--root", root.path(percentEncoded: false),
         "--state-dir", state.path(percentEncoded: false),
         "--sandbox-trash", sandbox.appending(path: ".trash", directoryHint: .isDirectory).path(percentEncoded: false),
         "--pasteboard", "macx-tests-\(UUID().uuidString)",
         "--fake-launch-services", "--skip-onboarding"]
    }

    func testRootWithoutStateDirExits64() throws {
        let r = try run(["--root", sandbox.path(percentEncoded: false)])
        XCTAssertEqual(r.status, 64)
        XCTAssertTrue(r.stderr.contains("--state-dir"), r.stderr)
    }

    func testUnknownOptionExits64() throws {
        let r = try run(["--definitely-not-an-option"])
        XCTAssertEqual(r.status, 64)
        XCTAssertTrue(r.stderr.contains("--definitely-not-an-option"), r.stderr)
    }

    func testMissingRootFolderExitsWithError() throws {
        let state = sandbox.appending(path: "state", directoryHint: .isDirectory)
        let r = try run(sandboxArguments(root: sandbox.appending(path: "nope", directoryHint: .isDirectory), state: state)
                        + ["--smoke-exit-after", "0"])
        XCTAssertEqual(r.status, 66)
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.appending(path: "smoke.json").path(percentEncoded: false)))
    }

    @MainActor func testSmokeExitOpensOneWindowTitledWithRootAndWritesReport() throws {
        _ = NSApplication.shared
        if NSScreen.screens.isEmpty { throw XCTSkip("needs a GUI login session (window server)") }
        let root = sandbox.appending(path: "Smoke Root", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let state = sandbox.appending(path: "state", directoryHint: .isDirectory)   // created by the app

        let r = try run(sandboxArguments(root: root, state: state) + ["--smoke-exit-after", "1"])
        XCTAssertEqual(r.status, 0, r.stderr)
        let report = try SmokeReport.read(from: state.appending(path: SmokeReport.fileName))
        XCTAssertEqual(report.windowTitles, ["Smoke Root"])
        XCTAssertEqual(report.root, root.path(percentEncoded: false))
        XCTAssertGreaterThan(report.processID, 0)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))
        XCTAssertEqual(leftovers, [], "the app writes nothing into the browsed folder")
    }

    @MainActor func testSandboxRunKeepsSettingsInTheStateDirectory() throws {
        _ = NSApplication.shared
        if NSScreen.screens.isEmpty { throw XCTSkip("needs a GUI login session (window server)") }
        let root = sandbox.appending(path: "Root", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let state = sandbox.appending(path: "state", directoryHint: .isDirectory)
        let r = try run(sandboxArguments(root: root, state: state) + ["--smoke-exit-after", "1.5"])
        XCTAssertEqual(r.status, 0, r.stderr)
        let settings = state.appending(path: "settings.json")
        let data = try Data(contentsOf: settings)
        let values = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(values["lastLocation"], "AppBootstrap uses FileSettingsStorage in <state-dir> (window navigation saved it)")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))
        XCTAssertEqual(leftovers, [])
    }
}
