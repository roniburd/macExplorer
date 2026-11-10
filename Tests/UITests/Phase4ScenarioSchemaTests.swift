import XCTest
import Core
import MacxFS
@testable import UI

/// P4-23: the Phase 4 scenario schema additions (launchArguments, archives fixture, answerError step, sheetTitle) and
/// the Phase 4 UI scenario files. Writes only into a macx-tests-* temp dir it creates.
final class Phase4ScenarioSchemaTests: XCTestCase {
    private static let dir = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Scenarios")

    private func load(_ body: String) -> ScenarioFile.ValidationError? {
        do { _ = try ScenarioFile.load(Data(body.utf8)); return nil } catch { return error as? ScenarioFile.ValidationError }
    }

    func testPhase4FieldsDecodeAndValidate() throws {
        let json = #"""
        {"name":"x","launchArguments":["--keymap","k-1.json"],"fixture":{"files":[],"dirs":["w"],"archives":{"w/e.tar":"evil-tar"}},
         "steps":[{"answerError":"skip"},{"expect":{"sheetTitle":"Rename 2 Items"}}]}
        """#
        let file = try ScenarioFile.load(Data(json.utf8))
        XCTAssertEqual(file.launchArguments, ["--keymap", "k-1.json"])
        XCTAssertEqual(file.fixture.archives, ["w/e.tar": "evil-tar"])
        XCTAssertEqual(file.steps[0].answerError, "skip")
        XCTAssertEqual(file.steps[0].actions, ["answerError"])
        XCTAssertEqual(file.steps[1].expect?.sheetTitle, "Rename 2 Items")
    }

    func testPhase4ValuesAreValidated() {
        let ok = #""fixture":{"files":[],"dirs":[]},"steps":[{"sleepMs":1}]"#
        XCTAssertNil(load(#"{"name":"x","# + ok + "}"))
        for args in [#"["--keymap","/etc/k.json"]"#, #"["--keymap","../k.json"]"#, #"["--keymap","k.txt"]"#, #"["--root","r"]"#,
                     #"["--keymap"]"#, #"["--keymap","k.json","--x"]"#] {
            XCTAssertNotNil(load(#"{"name":"x","launchArguments":"# + args + "," + ok + "}"), args)
        }
        XCTAssertEqual(load(#"{"name":"x","fixture":{"files":[],"dirs":[],"archives":{"a.zip":"bomb"}},"steps":[{"sleepMs":1}]}"#),
                       .badFixture("archive 'a.zip' kind 'bomb'"))
        XCTAssertEqual(load(#"{"name":"x","fixture":{"files":[],"dirs":[],"archives":{"../e.tar":"evil-tar"}},"steps":[{"sleepMs":1}]}"#),
                       .unsafePath("../e.tar"))
        XCTAssertEqual(load(#"{"name":"x","fixture":{"files":[],"dirs":[]},"steps":[{"answerError":"authenticate"}]}"#),
                       .badErrorAnswer(step: 0, "authenticate"))
    }

    func testEvilTarFixtureIsCreatedInsideTheRootOnly() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "macx-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let root = base.appending(path: "macx-scenario-root", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let file = try ScenarioFile.load(Data(#"{"name":"x","fixture":{"files":[],"dirs":["w"],"archives":{"w/e.tar":"evil-tar"}},"steps":[]}"#.utf8))
        let resolved = root.resolvingSymlinksInPath()
        try ScenarioFixtures.create(file.fixture, in: resolved)
        let data = try Data(contentsOf: resolved.appending(path: "w/e.tar"))
        XCTAssertEqual(data.count % 512, 0)
        XCTAssertEqual(String(decoding: data.prefix(13), as: UTF8.self), "../escape.txt")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: base.path), ["macx-scenario-root"], "nothing written next to the root")
        XCTAssertEqual(ScenarioFixtures.topLevelVisibleNames(file.fixture), ["w"])
    }

    /// QA round 2: symlink fixtures (safe relative link text only) and the hidden-local-zip archive kind.
    func testSymlinkAndHiddenLocalZipFixtures() throws {
        XCTAssertEqual(load(#"{"name":"x","fixture":{"files":[],"dirs":[],"symlinks":{"l":"../out"}},"steps":[{"sleepMs":1}]}"#),
                       .badFixture("symlink 'l' -> '../out'"))
        XCTAssertEqual(load(#"{"name":"x","fixture":{"files":[],"dirs":[],"symlinks":{"l":"/etc"}},"steps":[{"sleepMs":1}]}"#),
                       .badFixture("symlink 'l' -> '/etc'"))
        XCTAssertEqual(load(#"{"name":"x","fixture":{"files":[],"dirs":[],"symlinks":{"../l":"a"}},"steps":[{"sleepMs":1}]}"#),
                       .unsafePath("../l"))
        let base = FileManager.default.temporaryDirectory.appending(path: "macx-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let root = base.appending(path: "macx-scenario-root", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let json = #"{"name":"x","fixture":{"files":["a.txt"],"dirs":["w"],"symlinks":{"d/l":"a.txt"},"archives":{"w/h.zip":"hidden-local-zip"}},"steps":[]}"#
        let file = try ScenarioFile.load(Data(json.utf8))
        let resolved = root.resolvingSymlinksInPath()
        try ScenarioFixtures.create(file.fixture, in: resolved)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: resolved.appending(path: "d/l").path), "a.txt")
        let zip = try Data(contentsOf: resolved.appending(path: "w/h.zip"))
        XCTAssertEqual(Array(zip.prefix(4)), [0x50, 0x4B, 0x03, 0x04])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: base.path), ["macx-scenario-root"])
        XCTAssertEqual(ScenarioFixtures.topLevelVisibleNames(file.fixture), ["a.txt", "w", "d"])
    }

    func testSheetTitleExpectation() {
        var s = ProbeSnapshot()
        var e = ScenarioFile.Expectation()
        e.sheetTitle = ""
        XCTAssertEqual(ExpectationMatcher.mismatches(e, s), [])
        e.sheetTitle = "Rename 2 Items"
        XCTAssertEqual(ExpectationMatcher.mismatches(e, s).count, 1)
        s.sheetTitle = "Rename 2 Items"
        XCTAssertEqual(ExpectationMatcher.mismatches(e, s), [])
    }

    /// The Phase 4 UI scenarios (reduced scope: no tags, helper, network or dual pane) exist and load; the keymap one
    /// names a file in Tests/Scenarios/keymaps that imports cleanly.
    func testEveryPhase4ScenarioFileExists() throws {
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: Self.dir.path(percentEncoded: false)))
        for n in ["p4-keymap-import", "p4-palette-new-folder", "p4-compress-zip", "p4-extract-here", "p4-extract-unsafe", "p4-extract-link-chain", "p4-batch-rename",
                  "p4-compress-symlink", "p4-extract-hidden-local-zip"] {
            XCTAssertTrue(names.contains(n + ".json"), n)
            if names.contains(n + ".json") { XCTAssertNoThrow(try ScenarioFile.load(Data(contentsOf: Self.dir.appending(path: n + ".json"))), n) }
        }
        XCTAssertFalse(names.contains { $0.hasPrefix("p4-") && $0.contains("tag") }, "Phase 4 tags were removed (owner decision)")
        let file = try ScenarioFile.load(Data(contentsOf: Self.dir.appending(path: "p4-keymap-import.json")))
        let keymap = try XCTUnwrap(file.launchArguments?.last)
        let (overrides, warnings) = try KeymapDocument.import(Data(contentsOf: Self.dir.appending(path: "keymaps/\(keymap)")))
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(KeyBindings(overrides: overrides).primary(.newFolder), KeyChord(parsing: "cmd+opt+n"))
        let shiftN = try XCTUnwrap(KeyChord(parsing: "cmd+shift+n"))
        XCTAssertFalse(Command.allCases.contains { KeyBindings(overrides: overrides).primary($0) == shiftN }, "⌘⇧N is free")
    }
}
