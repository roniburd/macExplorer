import XCTest
@testable import UI

final class ScenarioFileTests: XCTestCase {
    private func load(_ json: String) throws -> ScenarioFile { try ScenarioFile.load(Data(json.utf8)) }

    func testContractExampleDecodes() throws {
        let f = try load(#"""
        {"name": "rename-f2", "fixture": {"files": ["a.txt", "b.txt"], "dirs": ["sub"]},
         "steps": [{"click": "a.txt"}, {"key": "F2"}, {"expect": {"renameText": "a.txt"}}, {"type": "c"}, {"key": "return"},
                   {"waitFor": {"rows": ["sub", "b.txt", "c.txt"]}, "timeoutMs": 2000},
                   {"expect": {"filesExist": ["c.txt"], "filesAbsent": ["a.txt"], "selection": ["c.txt"]}}]}
        """#)
        XCTAssertEqual(f.name, "rename-f2")
        XCTAssertEqual(f.steps.count, 7)
        XCTAssertEqual(f.steps[5].timeoutMs, 2000)
    }

    func testRejectsStepsWithZeroOrTwoActions() {
        XCTAssertThrowsError(try load(#"{"name":"x","fixture":{"files":[],"dirs":[]},"steps":[{"timeoutMs": 5}]}"#)) {
            XCTAssertEqual($0 as? ScenarioFile.ValidationError, .actionCount(step: 0, actions: []))
        }
        XCTAssertThrowsError(try load(#"{"name":"x","fixture":{"files":[],"dirs":[]},"steps":[{"key":"F2","click":"a"}]}"#)) {
            XCTAssertEqual($0 as? ScenarioFile.ValidationError, .actionCount(step: 0, actions: ["key", "click"]))
        }
    }

    func testRejectsUnknownValues() {
        let cases: [(String, ScenarioFile.ValidationError)] = [
            (#"{"key":"hyper+q"}"#, .badKey(step: 0, "hyper+q")),
            (#"{"answerConflict":"obliterate"}"#, .badConflictAction(step: 0, "obliterate")),
            (#"{"drop":{"sources":["a"],"onto":"b","choose":"symlink"}}"#, .badDropChoice(step: 0, "symlink")),
            (#"{"command":"launchRockets"}"#, .badCommand(step: 0, "launchRockets")),
            (#"{"click":"a","modifiers":["meta"]}"#, .badModifier(step: 0, "meta")),
        ]
        for (step, expected) in cases {
            XCTAssertThrowsError(try load(#"{"name":"x","fixture":{"files":[],"dirs":[]},"steps":["# + step + #"]}"#)) {
                XCTAssertEqual($0 as? ScenarioFile.ValidationError, expected, step)
            }
        }
    }

    func testRejectsUnsafeFixtureAndExpectationPaths() {
        for bad in ["../escape.txt", "/etc/hosts", "a/../../b", "~/x", "", "a//b", "./a"] {
            XCTAssertFalse(ScenarioPath.isSafeRelative(bad), bad)
        }
        XCTAssertTrue(ScenarioPath.isSafeRelative("dest/a copy.txt"))
        XCTAssertThrowsError(try load(#"{"name":"x","fixture":{"files":["../x"],"dirs":[]},"steps":[]}"#))
        XCTAssertThrowsError(try load(#"{"name":"x","fixture":{"files":[],"dirs":[]},"steps":[{"expect":{"filesExist":["/etc/hosts"]}}]}"#))
        XCTAssertThrowsError(try load(#"{"name":"x","fixture":{"files":[],"dirs":["d"],"modes":{"d":"999"}},"steps":[]}"#))
    }

    func testRejectsDropPathsThatLeaveTheFolder() {
        let cases: [(String, ScenarioFile.ValidationError)] = [
            (#"{"drop":{"sources":["../../../x"],"onto":"dest"}}"#, .unsafePath("../../../x")),
            (#"{"drop":{"sources":["a.txt","/etc/hosts"],"onto":"dest"}}"#, .unsafePath("/etc/hosts")),
            (#"{"drop":{"sources":["a.txt"],"onto":"../up"}}"#, .unsafePath("../up")),
        ]
        for (step, expected) in cases {
            XCTAssertThrowsError(try load(#"{"name":"x","fixture":{"files":[],"dirs":[]},"steps":["# + step + #"]}"#)) {
                XCTAssertEqual($0 as? ScenarioFile.ValidationError, expected, step)
            }
        }
        XCTAssertNoThrow(try load(#"{"name":"x","fixture":{"files":[],"dirs":[]},"steps":[{"drop":{"sources":["a.txt"],"onto":"dest"}}]}"#))
    }

    func testRejectsTypingAbsoluteOrHomePaths() {
        for text in ["/Users", "~/Desktop", "~"] {
            XCTAssertThrowsError(try load(#"{"name":"x","fixture":{"files":[],"dirs":[]},"steps":[{"type":""# + text + #""}]}"#)) {
                XCTAssertEqual($0 as? ScenarioFile.ValidationError, .unsafeTypedPath(step: 0, text), text)
            }
        }
        XCTAssertNoThrow(try load(#"{"name":"x","fixture":{"files":[],"dirs":[]},"steps":[{"type":"../../top.txt"}]}"#))
    }

    func testMouseStepValidates() throws {
        let ok = #"{"name": "m", "fixture": {"files": [], "dirs": []}, "steps": [{"mouse": "mouse4"}]}"#
        XCTAssertEqual(try ScenarioFile.load(Data(ok.utf8)).steps.first?.actions, ["mouse"])
        let bad = #"{"name": "m", "fixture": {"files": [], "dirs": []}, "steps": [{"mouse": "mouse2"}]}"#
        XCTAssertThrowsError(try ScenarioFile.load(Data(bad.utf8))) { error in
            XCTAssertEqual(error as? ScenarioFile.ValidationError, .badMouse(step: 0, "mouse2"))
        }
    }
}
