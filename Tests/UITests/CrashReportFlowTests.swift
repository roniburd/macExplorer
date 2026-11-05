import XCTest
import AppKit
import MacxFixtures
@testable import UI
@testable import Core

@MainActor
private final class ScriptedCrashPrompt: CrashPrompting {
    var answer: CrashAnswer
    private(set) var titles: [String] = []
    init(_ answer: CrashAnswer) { self.answer = answer }
    func ask(title: String, on window: NSWindow?) async -> CrashAnswer { titles.append(title); return answer }
}

@MainActor
final class CrashReportFlowTests: XCTestCase {
    private var sandbox: Sandbox!
    override func setUp() async throws { sandbox = try Sandbox() }
    override func tearDown() async throws { sandbox.destroy(); sandbox = nil }

    private let env = EnvironmentSummary(appVersion: "0.4.0", build: "812", channel: "release", macOS: "26.1", hardwareModel: "Mac16,10", architecture: "arm64")
    private let launched = Date(timeIntervalSince1970: 1_793_815_000)   // before the fixture's 10:11:12 -0800

    private func settings() -> Core.Settings {
        Settings(storage: InMemorySettingsStorage(), home: sandbox.root)
    }

    private func flow(_ s: Core.Settings, previous: PreviousSession, prompt: ScriptedCrashPrompt,
                      opener: RecordingURLOpener, copied: @escaping @MainActor (String) -> Void = { _ in },
                      revealed: @escaping @MainActor (URL) -> Void = { _ in }) throws -> CrashReportFlow {
        let dir = try sandbox.createDirectory("DiagnosticReports")
        _ = try sandbox.createFile("DiagnosticReports/macExplorer-2026-11-04-101112.ips",
                                   contents: Data(IPSFixture.make(home: "/Users/tester").utf8))
        return CrashReportFlow(settings: s, previous: previous,
                               locator: CrashReportLocator(directory: dir, bundleID: "com.macexplorer.app"),
                               home: "/Users/tester", environment: env, prompt: prompt, opener: opener,
                               copyText: copied, reveal: revealed)
    }

    private var dirty: PreviousSession { .dirty(SessionMarker(pid: 1, version: "0.4.0", build: "812", launchedAt: launched)) }

    func testCleanExitNeverAsks() async throws {
        let prompt = ScriptedCrashPrompt(CrashAnswer(choice: .report, dontAskAgain: false)), opener = RecordingURLOpener()
        let answer = try await flow(settings(), previous: .clean, prompt: prompt, opener: opener).run(on: nil)
        XCTAssertNil(answer)
        XCTAssertEqual(prompt.titles, [])
    }

    func testReportOpensIssueWithExcerptAndCopiesFullRedactedReport() async throws {
        let s = settings(), prompt = ScriptedCrashPrompt(CrashAnswer(choice: .report, dontAskAgain: false))
        let opener = RecordingURLOpener()
        var copied = ""
        let answer = try await flow(s, previous: dirty, prompt: prompt, opener: opener, copied: { copied = $0 }).run(on: nil)
        XCTAssertEqual(answer?.choice, .report)
        let url = try XCTUnwrap(opener.opened.first).absoluteString
        XCTAssertTrue(url.contains("template=bug.yml"))
        XCTAssertTrue(url.contains("crash-log="))
        XCTAssertFalse(url.contains("tester"))
        XCTAssertTrue(copied.contains("EXC_BAD_ACCESS"))
        XCTAssertFalse(copied.contains("/Users/tester"))
        XCTAssertEqual(s.lastReportedCrashes, ["macExplorer-2026-11-04-101112.ips"])
    }

    func testSameCrashNeverPromptsTwice() async throws {
        let s = settings(), prompt = ScriptedCrashPrompt(CrashAnswer(choice: .dontSend, dontAskAgain: false))
        let f = try flow(s, previous: dirty, prompt: prompt, opener: RecordingURLOpener())
        _ = await f.run(on: nil)
        _ = await f.run(on: nil)
        XCTAssertEqual(prompt.titles.count, 1)
    }

    func testDontAskAgainTurnsTheSettingOff() async throws {
        let s = settings(), prompt = ScriptedCrashPrompt(CrashAnswer(choice: .dontSend, dontAskAgain: true))
        _ = try await flow(s, previous: dirty, prompt: prompt, opener: RecordingURLOpener()).run(on: nil)
        XCTAssertFalse(s.offerToReportCrashes)
    }

    func testSettingOffNeverAsks() async throws {
        let s = settings()
        s.offerToReportCrashes = false
        let prompt = ScriptedCrashPrompt(CrashAnswer(choice: .report, dontAskAgain: false))
        let answer = try await flow(s, previous: dirty, prompt: prompt, opener: RecordingURLOpener()).run(on: nil)
        XCTAssertNil(answer)
        XCTAssertEqual(prompt.titles, [])
    }

    func testShowReportReveals() async throws {
        var revealed: URL?
        let prompt = ScriptedCrashPrompt(CrashAnswer(choice: .showReport, dontAskAgain: false))
        _ = try await flow(settings(), previous: dirty, prompt: prompt, opener: RecordingURLOpener(), revealed: { revealed = $0 }).run(on: nil)
        XCTAssertEqual(revealed?.lastPathComponent, "macExplorer-2026-11-04-101112.ips")
    }

    func testDirtyUnknownStillFindsUnreportedCrash() async throws {
        let prompt = ScriptedCrashPrompt(CrashAnswer(choice: .dontSend, dontAskAgain: false))
        _ = try await flow(settings(), previous: .dirtyUnknown, prompt: prompt, opener: RecordingURLOpener()).run(on: nil)
        XCTAssertEqual(prompt.titles.count, 1)
    }
}
