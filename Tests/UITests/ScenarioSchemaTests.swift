import XCTest
import Core
import MacxFS
@testable import UI

/// Phase 2 scenario schema (plan §2.4, P2-03): decoding, one-action validation, tokens and the fs-step guard.
final class ScenarioSchemaTests: XCTestCase {
    private static let phase2JSON = """
    {"name":"x","fixture":{"files":["a.txt"],"dirs":["A"],"images":["p.png"],"mtimeDays":{"a.txt":-1},
      "tags":{"a.txt":["Work"]},"comments":{"a.txt":"c"},"lastOpenedDays":{"a.txt":-3}},
     "steps":[{"middleClick":"A"},{"selectTab":1},{"answerAlert":"Apply"},
              {"fsWrite":{"path":"A/n.bin","bytes":10}},{"fsTags":{"path":"a.txt","tags":["Home"]}},
              {"expect":{"tabs":["","A"],"activeTab":0,"viewMode":"icons","sort":"name.asc","groups":["Today (1)"],
               "cells":{"a.txt":{"tags":"Work"}},"columnsChain":[""],"pasteboardText":"{root}/a.txt",
               "quickLookVisible":false,"thumbnailsContain":["p.png"],"visibleColumnsContain":["tags"]}}]}
    """

    func testPhase2FieldsDecode() throws {
        let file = try JSONDecoder().decode(ScenarioFile.self, from: Data(Self.phase2JSON.utf8))
        XCTAssertEqual(file.fixture.images, ["p.png"])
        XCTAssertEqual(file.fixture.mtimeDays, ["a.txt": -1])
        XCTAssertEqual(file.fixture.tags, ["a.txt": ["Work"]])
        XCTAssertEqual(file.fixture.comments, ["a.txt": "c"])
        XCTAssertEqual(file.fixture.lastOpenedDays, ["a.txt": -3])
        XCTAssertEqual(file.steps[0].middleClick, "A")
        XCTAssertEqual(file.steps[1].selectTab, 1)
        XCTAssertEqual(file.steps[3].fsWrite?.bytes, 10)
        XCTAssertEqual(file.steps[4].fsTags?.tags, ["Home"])
        XCTAssertEqual(file.steps[5].expect?.cells?["a.txt"]?["tags"], "Work")
        XCTAssertEqual(file.steps[5].expect?.tabs, ["", "A"])
        XCTAssertTrue(ScenarioDriver.validateSteps(file.steps).isEmpty)
        XCTAssertNoThrow(try ScenarioFile.load(Data(Self.phase2JSON.utf8)))
    }

    func testTwoActionsInOneStepAreRejected() throws {
        let json = #"{"name":"x","fixture":{"files":[],"dirs":[]},"steps":[{"middleClick":"A","selectTab":1}]}"#
        let file = try JSONDecoder().decode(ScenarioFile.self, from: Data(json.utf8))
        XCTAssertEqual(ScenarioDriver.validateSteps(file.steps), [0])
        XCTAssertThrowsError(try ScenarioFile.load(Data(json.utf8))) {
            XCTAssertEqual($0 as? ScenarioFile.ValidationError, .actionCount(step: 0, actions: ["middleClick", "selectTab"]))
        }
        for pair in [#"{"fsWrite":{"path":"a","bytes":1},"fsTags":{"path":"a","tags":[]}}"#, #"{"answerAlert":"OK","click":"a"}"#] {
            let two = #"{"name":"x","fixture":{"files":[],"dirs":[]},"steps":["# + pair + #"]}"#
            XCTAssertEqual(ScenarioDriver.validateSteps(try JSONDecoder().decode(ScenarioFile.self, from: Data(two.utf8)).steps), [0], pair)
        }
    }

    func testTokenSubstitution() {
        let root = URL(filePath: "/private/var/folders/x/macx-scenario-1", directoryHint: .isDirectory)
        XCTAssertEqual(ScenarioDriver.substitute("{root}/a.txt", root: root), "/private/var/folders/x/macx-scenario-1/a.txt")
        XCTAssertEqual(ScenarioDriver.substitute("{rootURL}a.txt", root: root), "file:///private/var/folders/x/macx-scenario-1/a.txt")
        XCTAssertEqual(ScenarioDriver.substitute("{user}", root: root), NSUserName())
        XCTAssertEqual(ScenarioDriver.substitute("plain", root: root), "plain")
    }

    func testExpectationStringsAreSubstituted() {
        let root = URL(filePath: "/tmp/macx-scenario-1", directoryHint: .isDirectory)
        var e = ScenarioFile.Expectation()
        e.pasteboardText = "{root}/a.txt"
        e.rows = ["{user}"]
        e.cells = ["a.txt": ["path": "{root}"]]
        e.quickLookItems = ["{rootURL}"]
        let s = e.substituted(root: root)
        XCTAssertEqual(s.pasteboardText, "/tmp/macx-scenario-1/a.txt")
        XCTAssertEqual(s.rows, [NSUserName()])
        XCTAssertEqual(s.cells?["a.txt"]?["path"], "/tmp/macx-scenario-1")
        XCTAssertEqual(s.quickLookItems, ["file:///tmp/macx-scenario-1/"])
    }

    func testFSStepsRefusePathsOutsideRoot() {
        let root = URL(filePath: "/tmp/macx-scenario-1", directoryHint: .isDirectory)
        XCTAssertNil(ScenarioDriver.guardedURL("../x", root: root))
        XCTAssertNil(ScenarioDriver.guardedURL("A/../../x", root: root))
        XCTAssertNil(ScenarioDriver.guardedURL("/etc/hosts", root: root))
        XCTAssertNil(ScenarioDriver.guardedURL("", root: root))
        XCTAssertEqual(ScenarioDriver.guardedURL("A/n.bin", root: root)?.path(percentEncoded: false), "/tmp/macx-scenario-1/A/n.bin")
        // And validation rejects them before the run starts.
        for step in [#"{"fsWrite":{"path":"../x","bytes":1}}"#, #"{"fsTags":{"path":"/etc/hosts","tags":["x"]}}"#] {
            let json = #"{"name":"x","fixture":{"files":[],"dirs":[]},"steps":["# + step + #"]}"#
            XCTAssertThrowsError(try ScenarioFile.load(Data(json.utf8)), step)
        }
    }

    func testPhase2FixturePathsAndTargetsAreValidated() {
        func load(fixture: String = "", step: String) throws -> ScenarioFile {
            let json: String = "{\"name\":\"x\",\"fixture\":{\"files\":[],\"dirs\":[]" + fixture + "},\"steps\":[" + step + "]}"
            return try ScenarioFile.load(Data(json.utf8))
        }
        let badFixtures: [String] = [#","images":["../p.png"]"#, #","tags":{"/etc/hosts":["x"]}"#, #","comments":{"~/x":"c"}"#,
                                     #","mtimeDays":{"a/../../b":1}"#, #","lastOpenedDays":{"..":1}"#]
        for fixture in badFixtures {
            XCTAssertThrowsError(try load(fixture: fixture, step: #"{"sleepMs":1}"#), fixture)
        }
        XCTAssertThrowsError(try load(step: #"{"selectTab":-1}"#)) {
            XCTAssertEqual($0 as? ScenarioFile.ValidationError, .badTab(step: 0, -1))
        }
        XCTAssertThrowsError(try load(step: #"{"doubleClick":"group:Today"}"#)) {
            XCTAssertEqual($0 as? ScenarioFile.ValidationError, .badTarget(step: 0, "group:Today"))
        }
        XCTAssertThrowsError(try load(step: #"{"click":"tree:../up"}"#)) {
            XCTAssertEqual($0 as? ScenarioFile.ValidationError, .badTarget(step: 0, "tree:../up"))
        }
        XCTAssertThrowsError(try load(step: #"{"middleClick":"tree:/etc"}"#))
        XCTAssertThrowsError(try load(step: #"{"expect":{"sort":"name.up"}}"#))
        XCTAssertThrowsError(try load(step: #"{"expect":{"iconSize":"huge"}}"#))
        XCTAssertThrowsError(try load(step: #"{"expect":{"groupBy":"color"}}"#))
        XCTAssertThrowsError(try load(step: #"{"expect":{"tabs":["../x"]}}"#))
        XCTAssertNoThrow(try load(step: #"{"click":"tree:"}"#))
        XCTAssertNoThrow(try load(step: #"{"click":"tree:A/B","modifiers":["cmd"]}"#))
        XCTAssertNoThrow(try load(step: #"{"rightClick":"header:tags"}"#))
        XCTAssertNoThrow(try load(step: #"{"expect":{"sort":"dateModified.desc","iconSize":"large","groupBy":"kind","tabs":[""]}}"#))
    }

    func testClickTargetParsing() {
        XCTAssertEqual(ScenarioTarget(parsing: "a.txt"), .row("a.txt"))
        XCTAssertEqual(ScenarioTarget(parsing: "tree:A/B"), .prefixed("tree:A/B"))
        XCTAssertEqual(ScenarioTarget(parsing: "group:Today"), .prefixed("group:Today"))
        XCTAssertEqual(ScenarioTarget(parsing: "header:size"), .prefixed("header:size"))
        XCTAssertEqual(ScenarioTarget(parsing: "notes: draft.txt"), .row("notes: draft.txt"), "only known prefixes route to hooks")
    }

    func testPhase2ExpectationsMatch() {
        var s = ProbeSnapshot()
        s.tabs = ["", "A"]
        s.activeTab = 1
        s.sort = "size.desc"
        s.iconSize = "large"
        s.groupBy = "kind"
        s.groups = ["Folders (1)", "Images (2)"]
        s.visibleRows = ["A", "p.png"]
        s.visibleColumns = ["name", "tags", "size"]
        s.quickLookVisible = true
        s.quickLookItems = ["p.png"]
        s.cells = ["a.txt": ["tags": "Work"]]
        s.columnsChain = ["", "A"]
        s.activeColumn = 1
        s.thumbnails = ["p.png", "q.png"]
        s.pasteboardText = "/tmp/a.txt"
        var e = ScenarioFile.Expectation()
        e.tabs = ["", "A"]; e.activeTab = 1; e.sort = "size.desc"; e.iconSize = "large"; e.groupBy = "kind"
        e.groups = ["Folders (1)", "Images (2)"]; e.visibleRows = ["A", "p.png"]; e.visibleColumnsContain = ["tags"]
        e.quickLookVisible = true; e.quickLookItems = ["p.png"]; e.cells = ["a.txt": ["tags": "Work"]]
        e.columnsChain = ["", "A"]; e.activeColumn = 1; e.thumbnailsContain = ["q.png"]; e.pasteboardText = "/tmp/a.txt"
        XCTAssertEqual(ExpectationMatcher.mismatches(e, s), [])

        e.groups = ["Folders (1)"]                // exact, not subset
        e.visibleColumnsContain = ["comments"]    // subset: missing
        e.cells = ["a.txt": ["tags": "Home"], "b.txt": ["tags": ""]]
        e.tabs = ["A"]
        e.sort = "size.asc"
        let m = ExpectationMatcher.mismatches(e, s)
        XCTAssertEqual(m.count, 6, m.joined(separator: "\n"))
        XCTAssertTrue(m.contains { $0.contains("b.txt") && $0.contains("tags") })
    }

    func testPhase2ExpectationsFailLoudlyWhenTheirHookIsMissing() {
        var e = ScenarioFile.Expectation()
        e.groups = []; e.visibleRows = []; e.visibleColumnsContain = []; e.quickLookVisible = false; e.quickLookItems = []
        e.cells = ["a": ["tags": ""]]; e.columnsChain = []; e.activeColumn = 0; e.thumbnailsContain = []
        e.pasteboardText = ""
        let m = ExpectationMatcher.mismatches(e, ProbeSnapshot())
        XCTAssertEqual(m.count, 10, m.joined(separator: "\n"))
        for hook in ["groupHeaderTitles", "visibleRowNames", "visibleColumnIDs", "quickLookState", "cellText", "columnsChain", "thumbnailNames"] {
            XCTAssertTrue(m.contains { $0.contains(hook) }, "no message names \(hook): \(m)")
        }
        XCTAssertTrue(m.contains { $0.contains("pasteboardText") && $0.contains("no snapshot") })
    }

    func testStringsForSortGroupingAndIconSize() {
        XCTAssertEqual(ScenarioStrings.sort(SortDescriptor(field: .dateModified, ascending: false)), "dateModified.desc")
        XCTAssertEqual(ScenarioStrings.sort(.default), "name.asc")
        XCTAssertEqual(ScenarioStrings.isValidSort("tags.asc"), true)
        XCTAssertEqual(ScenarioStrings.isValidSort("tags"), false)
    }

    func testAXIDsForPhase2Views() {
        XCTAssertEqual(AXID.groupHeader("Today"), "macx.group.Today")
        XCTAssertEqual(AXID.columnsView, "macx.columns")
        XCTAssertEqual(AXID.column(2), "macx.column.2")
        XCTAssertEqual(AXID.newTabItem, "macx.newTab")
        XCTAssertEqual(AXID.tabBarDrop, "macx.tabBarDrop")
    }
}
