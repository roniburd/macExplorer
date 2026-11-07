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
        s.iconsVisible = ["p.png", "q.png", "r.png"]
        s.pasteboardText = "/tmp/a.txt"
        var e = ScenarioFile.Expectation()
        e.tabs = ["", "A"]; e.activeTab = 1; e.sort = "size.desc"; e.iconSize = "large"; e.groupBy = "kind"
        e.groups = ["Folders (1)", "Images (2)"]; e.visibleRows = ["A", "p.png"]; e.visibleColumnsContain = ["tags"]
        e.quickLookVisible = true; e.quickLookItems = ["p.png"]; e.cells = ["a.txt": ["tags": "Work"]]
        e.columnsChain = ["", "A"]; e.activeColumn = 1; e.thumbnailsContain = ["q.png"]; e.pasteboardText = "/tmp/a.txt"
        e.iconsVisibleContain = ["r.png"]
        XCTAssertEqual(ExpectationMatcher.mismatches(e, s), [])

        e.groups = ["Folders (1)"]                // exact, not subset
        e.visibleColumnsContain = ["comments"]    // subset: missing
        e.cells = ["a.txt": ["tags": "Home"], "b.txt": ["tags": ""]]
        e.tabs = ["A"]
        e.sort = "size.asc"
        e.iconsVisibleContain = ["s.png"]         // subset: missing
        let m = ExpectationMatcher.mismatches(e, s)
        XCTAssertEqual(m.count, 7, m.joined(separator: "\n"))
        XCTAssertTrue(m.contains { $0.contains("b.txt") && $0.contains("tags") })
    }

    func testPhase2ExpectationsFailLoudlyWhenTheirHookIsMissing() {
        var e = ScenarioFile.Expectation()
        e.groups = []; e.visibleRows = []; e.visibleColumnsContain = []; e.quickLookVisible = false; e.quickLookItems = []
        e.cells = ["a": ["tags": ""]]; e.columnsChain = []; e.activeColumn = 0; e.thumbnailsContain = []
        e.pasteboardText = ""; e.iconsVisibleContain = []
        let m = ExpectationMatcher.mismatches(e, ProbeSnapshot())
        XCTAssertEqual(m.count, 11, m.joined(separator: "\n"))
        for hook in ["groupHeaderTitles", "visibleRowNames", "visibleColumnIDs", "quickLookState", "cellText", "columnsChain", "thumbnailNames",
                     "iconsVisibleNames"] {
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
    // MARK: Phase 3 (P3-13)

    func testPhase3SchemaDecodes() throws {
        let json = #"""
        {"name": "x", "indexStatus": "enabled",
         "fixture": {"files": [], "dirs": [], "contents": {"a.txt": "hi"}, "binary": {"b.bin": 64}, "bulk": {"many": 10},
                     "spotlight": [{"path": "a.txt"}, {"path": "Apps/X.app", "kind": "app"}]},
         "steps": [{"clickSidebar": "searches:Taxes"}, {"setSearchScope": "subfolders"},
                   {"expect": {"searchState": "complete", "resultCount": 2, "rowPaths": ["", "sub"], "notices": ["spotlightOff"],
                               "previewState": "text", "previewTextPrefix": "hi", "sidebarSearches": ["Taxes"]}}]}
        """#
        let file = try JSONDecoder().decode(ScenarioFile.self, from: Data(json.utf8))
        XCTAssertEqual(file.indexStatus, "enabled")
        XCTAssertEqual(file.fixture.spotlight?.count, 2)
        XCTAssertEqual(file.fixture.contents, ["a.txt": "hi"])
        XCTAssertEqual(file.fixture.binary, ["b.bin": 64])
        XCTAssertEqual(file.fixture.bulk, ["many": 10])
        XCTAssertEqual(file.steps[0].clickSidebar, "searches:Taxes")
        XCTAssertEqual(file.steps[1].setSearchScope, "subfolders")
        XCTAssertEqual(file.steps[2].expect?.rowPaths, ["", "sub"])
        XCTAssertEqual(file.steps[2].expect?.previewTextPrefix, "hi")
        XCTAssertTrue(ScenarioDriver.validateSteps(file.steps).isEmpty)
        XCTAssertNoThrow(try file.validate())      // exactly one action per step (P1-41 validator) and the new checks
    }

    func testPhase3ValuesAreValidated() throws {
        func load(_ step: String, fixture: String = #""files":[],"dirs":[]"#, indexStatus: String? = nil) -> ScenarioFile.ValidationError? {
            let status = indexStatus.map { #""indexStatus":""# + $0 + #"","# } ?? ""
            let json = #"{"name":"x","# + status + #""fixture":{"# + fixture + #"},"steps":["# + step + "]}"
            do { _ = try ScenarioFile.load(Data(json.utf8)); return nil } catch { return error as? ScenarioFile.ValidationError }
        }
        let ok = #"{"sleepMs":1}"#
        XCTAssertNil(load(ok))
        XCTAssertEqual(load(ok, indexStatus: "maybe"), .badIndexStatus("maybe"))
        XCTAssertEqual(load(#"{"clickSidebar":"favorites:Home"}"#), .badSidebarTarget(step: 0, "favorites:Home"))
        XCTAssertEqual(load(#"{"clickSidebar":"searches:"}"#), .badSidebarTarget(step: 0, "searches:"))
        XCTAssertEqual(load(#"{"setSearchScope":"everywhere"}"#), .badSearchScope(step: 0, "everywhere"))
        XCTAssertEqual(load(#"{"clickSidebar":"searches:A","setSearchScope":"thisMac"}"#),
                       .actionCount(step: 0, actions: ["clickSidebar", "setSearchScope"]))
        XCTAssertEqual(load(ok, fixture: #""files":[],"dirs":[],"contents":{"../x.txt":"hi"}"#), .unsafePath("../x.txt"))
        XCTAssertEqual(load(ok, fixture: #""files":[],"dirs":[],"spotlight":[{"path":"/etc/hosts"}]"#), .unsafePath("/etc/hosts"))
        XCTAssertEqual(load(ok, fixture: #""files":[],"dirs":[],"spotlight":[{"path":"a","kind":"volume"}]"#), .badFixture("spotlight 'a' kind 'volume'"))
        XCTAssertEqual(load(ok, fixture: #""files":[],"dirs":[],"bulk":{"d":0}"#), .badFixture("bulk 'd' count 0"))
        XCTAssertEqual(load(#"{"expect":{"rowPaths":["../up"]}}"#), .unsafePath("../up"))
        XCTAssertEqual(load(#"{"expect":{"searchState":"done"}}"#), .badExpectation(step: 0, "unknown searchState 'done'"))
        XCTAssertEqual(load(#"{"expect":{"notices":["oops"]}}"#), .badExpectation(step: 0, "unknown notice 'oops'"))
        XCTAssertNil(load(#"{"expect":{"notices":["diagnostic:size:big","contentsNotIndexed"],"rowPaths":["","a/b"]}}"#))
    }

    func testPhase3ExpectationsMatch() {
        var s = ProbeSnapshot()
        s.searchState = "complete"
        s.resultCount = 2
        s.rowPaths = ["", "a"]
        s.notices = ["diagnostic:size:big", "skippedLocations"]
        s.previewState = "text"
        s.previewText = "hello world"
        s.sidebarSearches = ["Taxes"]
        var e = ScenarioFile.Expectation()
        e.searchState = "complete"; e.resultCount = 2; e.rowPaths = ["", "a"]; e.notices = ["diagnostic:size:big", "skippedLocations"]
        e.previewState = "text"; e.previewTextPrefix = "hello"; e.sidebarSearches = ["Taxes"]
        XCTAssertEqual(ExpectationMatcher.mismatches(e, s), [])

        e.searchState = "stopped"; e.resultCount = 3; e.rowPaths = ["a", ""]; e.notices = ["skippedLocations"]
        e.previewState = "hidden"; e.previewTextPrefix = "world"; e.sidebarSearches = []
        XCTAssertEqual(ExpectationMatcher.mismatches(e, s).count, 7, ExpectationMatcher.mismatches(e, s).joined(separator: "\n"))

        var none = ProbeSnapshot()                     // folder shown: no results, pane collapsed
        none.previewText = nil
        var want = ScenarioFile.Expectation()
        want.searchState = "none"; want.previewState = "hidden"
        XCTAssertEqual(ExpectationMatcher.mismatches(want, none), [])
        want.resultCount = 0; want.previewTextPrefix = ""
        let m = ExpectationMatcher.mismatches(want, none)
        XCTAssertEqual(m.count, 2, m.joined(separator: "\n"))
        XCTAssertTrue(m.contains { $0.contains("no search results are shown") })
        XCTAssertTrue(m.contains { $0.contains("no text preview") })
    }

    func testPhase3FixturesAreCreatedInsideTheRoot() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "macx-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let root = base.appending(path: "macx-scenario-root", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let json = #"""
        {"name":"x","fixture":{"files":["top.txt"],"dirs":[],"contents":{"n/a.txt":"héllo"},"binary":{"b.zzq":300},"bulk":{"many":12},
                               "spotlight":[{"path":"n/a.txt"},{"path":"X.app","kind":"app","size":5}]},"steps":[]}
        """#
        let file = try ScenarioFile.load(Data(json.utf8))
        let resolved = root.resolvingSymlinksInPath()
        try ScenarioFixtures.create(file.fixture, in: resolved)
        XCTAssertEqual(try String(contentsOf: resolved.appending(path: "n/a.txt"), encoding: .utf8), "héllo")
        let bytes = try Data(contentsOf: resolved.appending(path: "b.zzq"))
        XCTAssertEqual(bytes.count, 300)
        XCTAssertEqual(bytes.first, 0)
        XCTAssertNil(String(data: bytes, encoding: .utf8), "binary fixtures are never valid UTF-8")
        XCTAssertEqual(bytes, ScenarioFixtures.binaryData(300), "deterministic")
        let many = try FileManager.default.contentsOfDirectory(atPath: resolved.appending(path: "many").path).sorted()
        XCTAssertEqual(many.count, 12)
        XCTAssertEqual(many.first, "file-000001.txt")
        XCTAssertEqual(ScenarioFixtures.topLevelVisibleNames(file.fixture), ["top.txt", "n", "b.zzq", "many"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: resolved.appending(path: "X.app").path), "spotlight items are not created")

        let items = ScenarioFixtures.metadataItems(file.fixture.spotlight ?? [], root: resolved)
        XCTAssertEqual(items.map(\.name), ["a.txt", "X.app"])
        XCTAssertEqual(items[0].path, resolved.standardizedFileURL.path(percentEncoded: false).trimmingSuffix("/") + "/n/a.txt")
        XCTAssertTrue(items[0].contentTypeTree.contains("public.plain-text"), "\(items[0].contentTypeTree)")
        XCTAssertTrue(items[0].contentTypeTree.contains("public.data"))
        XCTAssertEqual(items[1].contentTypeTree.first, "com.apple.application-bundle")
        XCTAssertEqual(items[1].size, 5)
        XCTAssertEqual(items[0].size, 1)
    }

    func testEveryPhase3ScenarioFileExists() throws {
        let dir = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Scenarios")
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false)))
        for n in ["search-this-folder-instant", "search-subfolders-crawl", "search-syntax-filters", "search-open-containing-folder",
                  "search-folder-result-back", "search-stop", "search-saved-sidebar", "search-saved-del-keeps-files",
                  "search-results-trash", "search-contents-not-indexed", "search-this-mac-fake-spotlight",
                  "preview-text", "preview-folder-multiple", "preview-optp-in-field"] {
            XCTAssertTrue(names.contains(n + ".json"), n)
            if names.contains(n + ".json") {
                XCTAssertNoThrow(try ScenarioFile.load(Data(contentsOf: dir.appending(path: n + ".json"))), n)
            }
        }
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String { hasSuffix(suffix) && count > 1 ? String(dropLast(suffix.count)) : self }
}
