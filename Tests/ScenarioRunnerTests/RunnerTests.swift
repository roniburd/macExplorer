import XCTest
import Darwin
@testable import macx_scenarios

@MainActor final class PathBox { var path: String? }

@MainActor
final class RunnerTests: XCTestCase {
    func testPassingScenarioCleansItsSandbox() async throws {
        let box = PathBox()
        let scenario = CoreScenario("test.pass") { ctx in
            box.path = ctx.sandbox.root.path
            ctx.file("a.txt")
        }
        let r = await ScenarioRunner.runOne(scenario, helper: nil, requireImages: false, keepSandbox: false)
        XCTAssertEqual(r.status, .passed, r.message ?? "")
        XCTAssertTrue(r.sandboxRemoved)
        let path = try XCTUnwrap(box.path)
        XCTAssertTrue(URL(filePath: path).lastPathComponent.hasPrefix("macx-scenario-"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testFailingScenarioReportsMessageAndStillCleansUp() async {
        let scenario = CoreScenario("test.fail") { ctx in
            let locked = ctx.file("locked.txt")
            try ctx.setFlags(locked, UInt32(UF_IMMUTABLE))
            let closed = ctx.dir("closed")
            ctx.file("closed/inner.txt")
            try ctx.setMode(closed, 0o000)
            throw ScenarioFailure("boom")
        }
        let r = await ScenarioRunner.runOne(scenario, helper: nil, requireImages: false, keepSandbox: false)
        XCTAssertEqual(r.status, .failed)
        XCTAssertTrue(r.message?.contains("boom") ?? false)
        XCTAssertTrue(r.sandboxRemoved, "uchg file and 000 folder must not block cleanup")
    }

    func testTimedOutScenarioIsCancelledAndCleanedUp() async {
        let scenario = CoreScenario("test.hang", timeout: .milliseconds(300)) { _ in
            try await Task.sleep(for: .seconds(3_600))
        }
        let clock = ContinuousClock()
        let start = clock.now
        let r = await ScenarioRunner.runOne(scenario, helper: nil, requireImages: false, keepSandbox: false)
        XCTAssertEqual(r.status, .failed)
        XCTAssertTrue(r.message?.contains("timed out") ?? false, r.message ?? "")
        XCTAssertTrue(r.sandboxRemoved)
        XCTAssertLessThan(clock.now - start, .seconds(30))
    }

    func testSkipBecomesFailureWhenImagesAreRequired() async {
        let scenario = CoreScenario("test.skip") { _ in throw ScenarioSkip("hdiutil missing") }
        let lenient = await ScenarioRunner.runOne(scenario, helper: nil, requireImages: false, keepSandbox: false)
        let strict = await ScenarioRunner.runOne(scenario, helper: nil, requireImages: true, keepSandbox: false)
        XCTAssertEqual(lenient.status, .skipped)
        XCTAssertEqual(strict.status, .failed)
    }

    func testImagesAreDetachedWhenScenarioThrows() async throws {
        guard SandboxHandle.imagesAvailable else { throw XCTSkip("hdiutil unavailable") }
        let box = PathBox()
        let scenario = CoreScenario("test.imageThrow", requires: .diskImages) { ctx in
            let image = try await ctx.image("t", .apfs, sizeMB: 16)
            box.path = image.mountPoint.path
            throw ScenarioFailure("after mount")
        }
        let r = await ScenarioRunner.runOne(scenario, helper: nil, requireImages: true, keepSandbox: false)
        XCTAssertEqual(r.status, .failed)
        XCTAssertFalse(ScenarioContext.isMounted(try XCTUnwrap(box.path, "image never mounted: \(r.message ?? "-")")))
        XCTAssertTrue(r.sandboxRemoved, "a still-mounted image would block removal")
    }

    func testRelativePathOfSandboxDescendant() throws {
        let handle = try SandboxHandle.make(prefix: "macx-scenario")
        defer { handle.destroy() }
        let mount = handle.dir("mnt-1")
        XCTAssertEqual(handle.relative(mount.appending(path: "a.txt")), "mnt-1/a.txt")
        XCTAssertEqual(handle.relative(URL(filePath: handle.root.path.replacingOccurrences(of: "/private/var/", with: "/var/")).appending(path: "w/b")), "w/b")
    }

    func testSandboxCreationIsReportedToTheManifestHook() async {
        let box = PathBox()
        ScenarioRunner.onSandboxCreated = { box.path = $0.path }
        defer { ScenarioRunner.onSandboxCreated = nil }
        let r = await ScenarioRunner.runOne(CoreScenario("test.hook") { _ in }, helper: nil, requireImages: false, keepSandbox: false)
        XCTAssertEqual(box.path, r.sandbox)
    }

    func testRealCatalogSubsetPasses() async {
        let selected = Catalog.select("ops.copyTree") + Catalog.select("clip.") + Catalog.select("undo.copy") + Catalog.select("browse.hidden")
        let report = await ScenarioRunner.run(selected, helper: nil, requireImages: false, keepSandbox: false) { _ in }
        XCTAssertEqual(report.failed, 0, report.results.filter { $0.status == .failed }.map { "\($0.name): \($0.message ?? "")" }.joined(separator: "\n"))
        XCTAssertTrue(report.results.allSatisfy(\.sandboxRemoved))
    }
}
