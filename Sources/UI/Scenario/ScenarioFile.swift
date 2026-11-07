import Core
import Foundation

/// §3.14 schema (field names and types exactly as in the contract) plus additive optional fields
/// (Contract note C6): Fixture.modes, Step.command, Step.answerAlert, Step.mouse, Expectation.rowCount/editingAddress/
/// viewMode/sheetPresent/propertiesWindows/windowCount/fileSizes. Phase 2 (plan §2.4, P2-03) adds the fixture
/// metadata fields, the middleClick/selectTab/fsWrite/fsTags actions, prefixed click targets and the view/tab
/// expectations. Phase 3 (plan P3-13) adds `indexStatus`, the contents/binary/bulk/spotlight fixtures, the
/// clickSidebar/setSearchScope steps and the search/preview expectations.
struct ScenarioFile: Codable {
    /// An item the fake Spotlight returns for every query (P3-13). `path` is relative to --root; kind "file" (default),
    /// "folder" or "app"; size in bytes (default 1). Nothing is created on disk for it.
    struct SpotlightFixture: Codable, Equatable {
        var path: String
        var kind: String?
        var size: Int?
        static let kinds: Set<String> = ["file", "folder", "app"]
    }
    struct Fixture: Codable {
        var files: [String]
        var dirs: [String]
        var hidden: [String]?
        var sizes: [String: Int]?
        var modes: [String: String]?          // additive: octal mode applied after creation, deepest first
        // Phase 2 (§2.4)
        var images: [String]?                 // 64×64 solid-colour PNGs at these paths
        var mtimeDays: [String: Int]?         // path → noon local time, N days from today (0 today, -1 yesterday)
        var tags: [String: [String]]?         // Finder tags xattr
        var comments: [String: String]?       // Finder comment xattr
        var lastOpenedDays: [String: Int]?    // com.apple.lastuseddate#PS at noon N days from today
        // Phase 3 (P3-13)
        var contents: [String: String]?       // file → UTF-8 text (parents made)
        var binary: [String: Int]?            // file → N deterministic bytes that are never valid text
        var bulk: [String: Int]?              // dir → N empty files "file-000001.txt"… (FixtureTree.flat naming)
        var spotlight: [SpotlightFixture]?    // what the fake Spotlight returns (not created on disk)

        /// Every relative path the fixture names (validated before anything is created).
        var allPaths: [String] {
            files + dirs + (hidden ?? []) + (images ?? []) + Array((sizes ?? [:]).keys) + Array((modes ?? [:]).keys)
                + Array((mtimeDays ?? [:]).keys) + Array((tags ?? [:]).keys) + Array((comments ?? [:]).keys)
                + Array((lastOpenedDays ?? [:]).keys) + Array((contents ?? [:]).keys) + Array((binary ?? [:]).keys)
                + Array((bulk ?? [:]).keys) + (spotlight ?? []).map(\.path)
        }
    }
    struct FSWrite: Codable { var path: String; var bytes: Int }
    struct FSTags: Codable { var path: String; var tags: [String] }
    struct Step: Codable {
        var key: String?
        var type: String?
        var menu: [String]?
        var click: String?
        var doubleClick: String?
        var rightClick: String?
        var modifiers: [String]?
        var chooseMenuItem: String?
        var drop: Drop?
        var answerConflict: String?
        var applyToAll: Bool?
        var waitFor: Expectation?
        var timeoutMs: Int?
        var expect: Expectation?
        var sleepMs: Int?
        var command: String?                  // additive: Command raw value, performed via its main-menu item
        var answerAlert: String?              // additive: press this button of an AppKit alert/sheet
        // Phase 2 (§2.4)
        var middleClick: String?              // click target (see ScenarioTarget)
        var selectTab: Int?                   // tab index in the key window's tab group
        var fsWrite: FSWrite?                 // {path, bytes}: writes inside --root (guarded), simulating another app
        var fsTags: FSTags?                   // {path, tags}: rewrites the tags xattr inside --root (guarded)
        var mouse: String?                    // additive: "mouse4" = buttonNumber 3, via MacxApplication.sendEvent
        // Phase 3 (P3-13)
        var clickSidebar: String?             // "searches:<saved search name>" (only SEARCHES rows: never real folders)
        var setSearchScope: String?           // "thisFolder" | "subfolders" | "thisMac", via the View › Search menu item

        var actions: [String] {
            let named: [(String, Bool)] = [
                ("key", key != nil), ("mouse", mouse != nil), ("type", type != nil), ("menu", menu != nil), ("command", command != nil),
                ("click", click != nil), ("doubleClick", doubleClick != nil), ("rightClick", rightClick != nil),
                ("chooseMenuItem", chooseMenuItem != nil), ("drop", drop != nil), ("answerConflict", answerConflict != nil),
                ("answerAlert", answerAlert != nil), ("waitFor", waitFor != nil), ("expect", expect != nil), ("sleepMs", sleepMs != nil),
                ("middleClick", middleClick != nil), ("selectTab", selectTab != nil), ("fsWrite", fsWrite != nil),
                ("fsTags", fsTags != nil), ("clickSidebar", clickSidebar != nil), ("setSearchScope", setSearchScope != nil),
            ]
            return named.filter { $0.1 }.map { $0.0 }
        }
    }
    struct Drop: Codable {
        var sources: [String]
        var onto: String
        var secondary: Bool?
        var choose: String?
    }
    struct Expectation: Codable {
        var rows: [String]?
        var rowsContain: [String]?
        var selection: [String]?
        var cut: [String]?
        var folder: String?
        var state: String?
        var focus: String?
        var fieldEditorText: String?
        var renameText: String?
        var emptyState: String?               // substring match (Contract note C6)
        var banner: String?                   // substring match
        var filesExist: [String]?
        var filesAbsent: [String]?
        var rowCount: Int?
        var editingAddress: Bool?
        var viewMode: String?
        var sheetPresent: Bool?
        var propertiesWindows: Int?
        var windowCount: Int?
        var fileSizes: [String: Int]?
        // Phase 2 (§2.4). Every string is token-substituted first (ScenarioDriver.substitute).
        var tabs: [String]?                   // tab folders relative to --root, "" = the root, in tab order
        var activeTab: Int?
        var sort: String?                     // "<SortField raw>.<asc|desc>"
        var iconSize: String?                 // IconSize raw value
        var groupBy: String?                  // GroupBy raw value
        var groups: [String]?                 // group header titles, exact ("Today (2)")
        var visibleRows: [String]?            // item rows in the table (headers excluded), exact
        var visibleColumnsContain: [String]?  // ColumnID raw values, subset
        var quickLookVisible: Bool?
        var quickLookItems: [String]?         // exact
        var cells: [String: [String: String]]? // row name → ColumnID raw → text
        var columnsChain: [String]?           // Columns view folders relative to --root, exact
        var activeColumn: Int?
        var thumbnailsContain: [String]?      // subset
        var iconsVisibleContain: [String]?    // Icons items in the visible rect (geometry, no thumbnails needed), subset
        var pasteboardText: String?
        // Phase 3 (P3-13)
        var searchState: String?              // "none" | "searching" | "complete" | "stopped" | "failed"
        var resultCount: Int?                 // rows of the shown results (fails while no results show)
        var rowPaths: [String]?               // per row, its parent folder relative to --root ("" = root), display order
        var notices: [String]?                // exact: "contentsNotIndexed", "spotlightOff", "truncated",
                                              //   "skippedLocations", "mayNotBeIndexed", "diagnostic:<token>"
        var previewState: String?             // PreviewPaneController.probeState; "hidden" = pane collapsed
        var previewTextPrefix: String?
        var sidebarSearches: [String]?        // SEARCHES rows, in order
    }
    var name: String
    var indexStatus: String?                  // P3-13: --index-status for this file ("enabled" | "disabled" | "unknown")
    var fixture: Fixture
    var steps: [Step]

    enum ValidationError: Error, Equatable, CustomStringConvertible {
        case actionCount(step: Int, actions: [String])
        case badKey(step: Int, String)
        case badConflictAction(step: Int, String)
        case badDropChoice(step: Int, String)
        case badCommand(step: Int, String)
        case badModifier(step: Int, String)
        case unsafePath(String)
        case unsafeTypedPath(step: Int, String)
        case badMode(String, String)
        case badTab(step: Int, Int)
        case badTarget(step: Int, String)
        case badExpectation(step: Int, String)
        case badSize(step: Int, Int)
        case badMouse(step: Int, String)
        case badIndexStatus(String)
        case badFixture(String)
        case badSidebarTarget(step: Int, String)
        case badSearchScope(step: Int, String)
        var description: String {
            switch self {
            case .actionCount(let s, let a): "step \(s): exactly one action required, found \(a)"
            case .badKey(let s, let k): "step \(s): key '\(k)' cannot be parsed or synthesized"
            case .badConflictAction(let s, let a): "step \(s): unknown conflict action '\(a)'"
            case .badDropChoice(let s, let c): "step \(s): unsupported drop choice '\(c)' (copy, move, alias, cancel; see Contract note C5)"
            case .badCommand(let s, let c): "step \(s): unknown command '\(c)'"
            case .badModifier(let s, let m): "step \(s): unknown modifier '\(m)' (cmd, shift, opt, ctrl)"
            case .unsafePath(let p): "unsafe relative path '\(p)'"
            case .unsafeTypedPath(let s, let t): "step \(s): typed text '\(t)' is an absolute or home path outside --root"
            case .badMode(let p, let m): "bad octal mode '\(m)' for '\(p)'"
            case .badTab(let s, let i): "step \(s): tab index \(i) must be ≥ 0"
            case .badTarget(let s, let t): "step \(s): unsupported click target '\(t)' (prefixed targets: tree:<path in root>, group:, header:; doubleClick takes row names only)"
            case .badExpectation(let s, let what): "step \(s): \(what)"
            case .badSize(let s, let n): "step \(s): fsWrite bytes \(n) must be in 0...\(ScenarioFile.maxWriteBytes)"
            case .badMouse(let s, let m): "step \(s): mouse button '\(m)' must be mouse4…mouse9"
            case .badIndexStatus(let v): "indexStatus '\(v)' must be enabled, disabled or unknown"
            case .badFixture(let what): "fixture: \(what)"
            case .badSidebarTarget(let s, let t): "step \(s): clickSidebar '\(t)' must be 'searches:<name>' (scenarios never open real folders from the sidebar)"
            case .badSearchScope(let s, let v): "step \(s): setSearchScope '\(v)' must be thisFolder, subfolders or thisMac"
            }
        }
    }

    static let modifierNames: Set<String> = ["cmd", "shift", "opt", "ctrl"]
    static let dropChoices: Set<String> = ["copy", "move", "alias", "cancel"]
    static let maxWriteBytes = 64 << 20
    static let maxBulkFiles = 100_000
    static let searchScopes: Set<String> = ["thisFolder", "subfolders", "thisMac"]
    static let sidebarSections: Set<String> = ["searches"]

    /// "searches:Taxes" → ("searches", "Taxes"); nil unless the section is allowed and the name is not empty.
    static func sidebarTarget(_ raw: String) -> (section: String, name: String)? {
        guard let colon = raw.firstIndex(of: ":") else { return nil }
        let section = String(raw[..<colon]), name = String(raw[raw.index(after: colon)...])
        guard sidebarSections.contains(section), !name.isEmpty else { return nil }
        return (section, name)
    }

    func validate() throws(ValidationError) {
        for path in fixture.allPaths where !ScenarioPath.isSafeRelative(path) { throw .unsafePath(path) }
        for (path, mode) in fixture.modes ?? [:] where mode.count > 4 || UInt16(mode, radix: 8) == nil { throw .badMode(path, mode) }
        if let status = indexStatus, IndexingStatus(rawValue: status) == nil { throw .badIndexStatus(status) }
        for (path, n) in fixture.binary ?? [:] where !(1...Self.maxWriteBytes).contains(n) { throw .badFixture("binary '\(path)' size \(n)") }
        for (path, n) in fixture.bulk ?? [:] where !(1...Self.maxBulkFiles).contains(n) { throw .badFixture("bulk '\(path)' count \(n)") }
        for item in fixture.spotlight ?? [] {
            if let kind = item.kind, !SpotlightFixture.kinds.contains(kind) { throw .badFixture("spotlight '\(item.path)' kind '\(kind)'") }
            if let size = item.size, size < 0 { throw .badFixture("spotlight '\(item.path)' size \(size)") }
        }
        for (index, step) in steps.enumerated() {
            let actions = step.actions
            guard actions.count == 1 else { throw .actionCount(step: index, actions: actions) }
            if let key = step.key, KeyChord(parsing: key).flatMap(KeySynth.spec(for:)) == nil { throw .badKey(step: index, key) }
            if let mouse = step.mouse, MouseButton(parsing: mouse) == nil { throw .badMouse(step: index, mouse) }
            if let action = step.answerConflict, ConflictAction(rawValue: action) == nil { throw .badConflictAction(step: index, action) }
            if let choice = step.drop?.choose, !Self.dropChoices.contains(choice) { throw .badDropChoice(step: index, choice) }
            if let command = step.command, Command(rawValue: command) == nil { throw .badCommand(step: index, command) }
            for modifier in step.modifiers ?? [] where !Self.modifierNames.contains(modifier) { throw .badModifier(step: index, modifier) }
            if let text = step.type, text.hasPrefix("/") || text.hasPrefix("~") { throw .unsafeTypedPath(step: index, text) }
            if let tab = step.selectTab, tab < 0 { throw .badTab(step: index, tab) }
            for target in [step.click, step.rightClick, step.middleClick].compactMap({ $0 }) where !ScenarioTarget.isValid(target) {
                throw .badTarget(step: index, target)
            }
            if let target = step.doubleClick, ScenarioTarget(parsing: target) != .row(target) { throw .badTarget(step: index, target) }
            if let bytes = step.fsWrite?.bytes, !(0...Self.maxWriteBytes).contains(bytes) { throw .badSize(step: index, bytes) }
            if let target = step.clickSidebar, Self.sidebarTarget(target) == nil { throw .badSidebarTarget(step: index, target) }
            if let scope = step.setSearchScope, !Self.searchScopes.contains(scope) { throw .badSearchScope(step: index, scope) }
            for expectation in [step.waitFor, step.expect].compactMap({ $0 }) {
                if let problem = ExpectationMatcher.formatProblem(expectation) { throw .badExpectation(step: index, problem) }
            }
            let dropPaths = step.drop.map { $0.sources + [$0.onto] } ?? []
            let fsPaths = [step.fsWrite?.path, step.fsTags?.path].compactMap { $0 }
            let paths = dropPaths + fsPaths + (step.waitFor.map(ExpectationMatcher.requestedPaths) ?? [])
                + (step.expect.map(ExpectationMatcher.requestedPaths) ?? [])
            for path in paths where !ScenarioPath.isSafeRelative(path) { throw .unsafePath(path) }
            let folderPaths = [step.waitFor, step.expect].compactMap { $0 }
                .flatMap { ($0.tabs ?? []) + ($0.columnsChain ?? []) + ($0.rowPaths ?? []) }
            for path in folderPaths where !path.isEmpty && !ScenarioPath.isSafeRelative(path) { throw .unsafePath(path) }
        }
    }

    static func load(_ data: Data) throws -> ScenarioFile {
        let file = try JSONDecoder().decode(ScenarioFile.self, from: data)
        try file.validate()
        return file
    }
}

/// A click / rightClick / middleClick target (§2.4): a row name in the active list (or active column), or a
/// prefixed target that the owning task's hook resolves: "tree:<path relative to root>" ("" = the root node),
/// "group:<group title>", "header:<ColumnID raw value>". Only these prefixes route to hooks, so a row whose name
/// contains ":" still works as a plain row.
enum ScenarioTarget: Equatable {
    case row(String)
    case prefixed(String)

    static let prefixes = ["tree:", "group:", "header:"]

    init(parsing raw: String) {
        self = Self.prefixes.contains(where: raw.hasPrefix) ? .prefixed(raw) : .row(raw)
    }

    /// tree: paths must stay inside the root; group: and header: need a non-empty name.
    static func isValid(_ raw: String) -> Bool {
        if raw.hasPrefix("tree:") {
            let path = String(raw.dropFirst("tree:".count))
            return path.isEmpty || ScenarioPath.isSafeRelative(path)
        }
        if let prefix = prefixes.first(where: raw.hasPrefix) { return raw.count > prefix.count }
        return true
    }
}

enum ScenarioPath {
    /// Non-empty, relative, no "~", and no empty, "." or ".." components.
    static func isSafeRelative(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
