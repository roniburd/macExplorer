import Core
import Foundation
import MacxFS

struct ProbeSnapshot: Equatable {
    var rows: [String] = []
    var selection: [String] = []
    var cut: [String] = []
    var folder: String? = ""                 // relative to --root; nil = outside it
    var state = "complete"
    var focus = "content"
    var fieldEditorText: String?
    var renameText: String?
    var emptyState: String?
    var banner: String?
    var editingAddress = false
    var viewMode = "details"
    var sheetPresent = false
    var sheetTitle = ""                      // P4-23: "" = no sheet
    var propertiesWindows = 0
    var windowCount = 1
    var fileSizes: [String: Int] = [:]       // requested paths that exist → st_size
    // Phase 2 (§2.4). Hook-backed values are nil while their hook is not installed, so an expectation on them
    // fails naming the hook instead of passing silently.
    var tabs: [String] = [""]                // relative to --root; a tab outside it is "<outside root: path>"
    var activeTab = 0
    var sort = "name.asc"
    var iconSize = "medium"
    var groupBy = "none"
    var groups: [String]?                    // ScenarioHooks.groupHeaderTitles
    var visibleRows: [String]?               // ScenarioHooks.visibleRowNames
    var visibleColumns: [String]?            // ScenarioHooks.visibleColumnIDs
    var quickLookVisible: Bool?              // ScenarioHooks.quickLookState
    var quickLookItems: [String]?            // ScenarioHooks.quickLookState
    var cells: [String: [String: String]]?   // ScenarioHooks.cellText, requested cells that exist
    var columnsChain: [String]?              // ScenarioHooks.columnsChain
    var activeColumn: Int?                   // ScenarioHooks.columnsChain
    var thumbnails: [String]?                // ScenarioHooks.thumbnailNames
    var iconsVisible: [String]?              // ScenarioHooks.iconsVisibleNames
    var pasteboardText: String?              // clipboard backend readString() (P2-04), "" = no text
    // Phase 3 (P3-13)
    var searchState = "none"                 // "none" while no results show
    var resultCount: Int?                    // nil while no results show
    var rowPaths: [String] = []              // relative to --root ("" = root); outside it "<outside root: path>"
    var notices: [String] = []
    var previewState = "hidden"
    var previewText: String?
    var sidebarSearches: [String] = []
    var windowStates: [String] = []          // every browser window's folder state, in window-list order
    var showHidden = false
}

enum ScenarioStrings {
    static func state(_ s: FolderState) -> String {
        switch s {
        case .loading: "loading"
        case .partial: "partial"
        case .complete: "complete"
        case .unresponsive: "unresponsive"
        case .waitingForPermission: "waitingForPermission"
        case .error(let r): "error." + reason(r)
        }
    }
    static func reason(_ r: Reason) -> String {
        switch r {
        case .notFound: "notFound"
        case .notADirectory: "notADirectory"
        case .permissionPOSIX: "permissionPOSIX"
        case .permissionTCC: "permissionTCC"
        case .volumeGone: "volumeGone"
        case .other(let code): "other.\(code)"
        }
    }
    static func focus(_ f: FocusContext) -> String { String(describing: f) }
    static func sort(_ d: MacxFS.SortDescriptor) -> String { "\(d.field.rawValue).\(d.ascending ? "asc" : "desc")" }
    static func isValidSort(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 2 && SortField(rawValue: String(parts[0])) != nil && ["asc", "desc"].contains(parts[1])
    }
}

extension ScenarioFile.Expectation {
    /// Every expected string with the scenario tokens replaced (§2.4). Relative-path fields (folder, tabs,
    /// columnsChain, filesExist, filesAbsent, fileSizes) are validated as paths and are left alone.
    func substituted(root: URL) -> Self {
        func sub(_ s: String) -> String { ScenarioDriver.substitute(s, root: root) }
        var e = self
        e.rows = rows?.map(sub)
        e.rowsContain = rowsContain?.map(sub)
        e.selection = selection?.map(sub)
        e.cut = cut?.map(sub)
        e.fieldEditorText = fieldEditorText.map(sub)
        e.renameText = renameText.map(sub)
        e.emptyState = emptyState.map(sub)
        e.banner = banner.map(sub)
        e.groups = groups?.map(sub)
        e.visibleRows = visibleRows?.map(sub)
        e.quickLookItems = quickLookItems?.map(sub)
        e.cells = cells.map { $0.mapValues { $0.mapValues(sub) } }
        e.thumbnailsContain = thumbnailsContain?.map(sub)
        e.iconsVisibleContain = iconsVisibleContain?.map(sub)
        e.pasteboardText = pasteboardText.map(sub)
        e.notices = notices?.map(sub)
        e.previewTextPrefix = previewTextPrefix.map(sub)
        e.sidebarSearches = sidebarSearches?.map(sub)
        return e
    }
}

enum ExpectationMatcher {
    static func requestedPaths(_ e: ScenarioFile.Expectation) -> [String] {
        (e.filesExist ?? []) + (e.filesAbsent ?? []) + Array((e.fileSizes ?? [:]).keys)
    }

    /// A malformed enum-like expectation value (checked at load time), or nil.
    static func formatProblem(_ e: ScenarioFile.Expectation) -> String? {
        if let sort = e.sort, !ScenarioStrings.isValidSort(sort) { return "sort '\(sort)' is not '<field>.<asc|desc>'" }
        if let size = e.iconSize, IconSize(rawValue: size) == nil { return "unknown iconSize '\(size)'" }
        if let group = e.groupBy, GroupBy(rawValue: group) == nil { return "unknown groupBy '\(group)'" }
        if let mode = e.viewMode, ViewMode(rawValue: mode) == nil { return "unknown viewMode '\(mode)'" }
        if let state = e.searchState, !searchStates.contains(state) { return "unknown searchState '\(state)'" }
        for notice in e.notices ?? [] where !noticeKinds.contains(notice) && !(notice.hasPrefix("diagnostic:") && notice.count > 11) {
            return "unknown notice '\(notice)'"
        }
        return nil
    }

    static let searchStates: Set<String> = ["none", "searching", "complete", "stopped", "failed"]
    static let noticeKinds: Set<String> = ["contentsNotIndexed", "spotlightOff", "truncated", "skippedLocations", "mayNotBeIndexed"]

    static func mismatches(_ e: ScenarioFile.Expectation, _ s: ProbeSnapshot) -> [String] {
        var m: [String] = []
        func check<T: Equatable>(_ label: String, _ expected: T?, _ actual: T) {
            if let expected, expected != actual { m.append("\(label): expected \(expected), got \(actual)") }
        }
        check("rows", e.rows, s.rows)
        if let want = e.rowsContain {
            let missing = want.filter { !s.rows.contains($0) }
            if !missing.isEmpty { m.append("rowsContain: missing \(missing) in \(s.rows)") }
        }
        check("rowCount", e.rowCount, s.rows.count)
        if let want = e.selection, Set(want) != Set(s.selection) { m.append("selection: expected \(want), got \(s.selection)") }
        if let want = e.cut, Set(want) != Set(s.cut) { m.append("cut: expected \(want), got \(s.cut)") }
        if let want = e.folder, want != s.folder {
            m.append("folder: expected '\(want)', got \(s.folder.map { "'\($0)'" } ?? "a folder outside root")")
        }
        check("state", e.state, s.state)
        check("focus", e.focus, s.focus)
        if let want = e.fieldEditorText, want != s.fieldEditorText { m.append("fieldEditorText: expected '\(want)', got \(String(describing: s.fieldEditorText))") }
        if let want = e.renameText, want != s.renameText { m.append("renameText: expected '\(want)', got \(String(describing: s.renameText))") }
        if let want = e.emptyState, !(s.emptyState?.contains(want) ?? false) { m.append("emptyState: expected to contain '\(want)', got \(String(describing: s.emptyState))") }
        if let want = e.banner, !(s.banner?.contains(want) ?? false) { m.append("banner: expected to contain '\(want)', got \(String(describing: s.banner))") }
        check("editingAddress", e.editingAddress, s.editingAddress)
        check("viewMode", e.viewMode, s.viewMode)
        check("sheetPresent", e.sheetPresent, s.sheetPresent)
        check("sheetTitle", e.sheetTitle, s.sheetTitle)
        check("propertiesWindows", e.propertiesWindows, s.propertiesWindows)
        check("windowCount", e.windowCount, s.windowCount)
        for path in e.filesExist ?? [] where s.fileSizes[path] == nil { m.append("filesExist: '\(path)' is missing") }
        for path in e.filesAbsent ?? [] where s.fileSizes[path] != nil { m.append("filesAbsent: '\(path)' exists") }
        for (path, size) in (e.fileSizes ?? [:]).sorted(by: { $0.key < $1.key }) where s.fileSizes[path] != size {
            m.append("fileSizes: '\(path)' expected \(size) bytes, got \(s.fileSizes[path].map { String($0) } ?? "missing")")
        }
        phase2Mismatches(e, s, into: &m)
        phase3Mismatches(e, s, into: &m)
        return m
    }
}

extension ExpectationMatcher {
    private static func missingHook(_ label: String, _ hook: String) -> String {
        "\(label): ScenarioHooks.\(hook) is not installed (the owning task has not landed), cannot check"
    }

    static func phase2Mismatches(_ e: ScenarioFile.Expectation, _ s: ProbeSnapshot, into m: inout [String]) {
        func check<T: Equatable>(_ label: String, _ expected: T?, _ actual: T) {
            if let expected, expected != actual { m.append("\(label): expected \(expected), got \(actual)") }
        }
        /// Exact match against a hook value; nil actual = hook missing.
        func hooked<T: Equatable>(_ label: String, _ expected: T?, _ actual: T?, hook: String) {
            guard let expected else { return }
            guard let actual else { return m.append(missingHook(label, hook)) }
            if expected != actual { m.append("\(label): expected \(expected), got \(actual)") }
        }
        func subset(_ label: String, _ expected: [String]?, _ actual: [String]?, hook: String) {
            guard let expected else { return }
            guard let actual else { return m.append(missingHook(label, hook)) }
            let missing = expected.filter { !actual.contains($0) }
            if !missing.isEmpty { m.append("\(label): missing \(missing) in \(actual)") }
        }
        check("tabs", e.tabs, s.tabs)
        check("activeTab", e.activeTab, s.activeTab)
        check("sort", e.sort, s.sort)
        check("iconSize", e.iconSize, s.iconSize)
        check("groupBy", e.groupBy, s.groupBy)
        hooked("groups", e.groups, s.groups, hook: "groupHeaderTitles")
        hooked("visibleRows", e.visibleRows, s.visibleRows, hook: "visibleRowNames")
        subset("visibleColumnsContain", e.visibleColumnsContain, s.visibleColumns, hook: "visibleColumnIDs")
        hooked("quickLookVisible", e.quickLookVisible, s.quickLookVisible, hook: "quickLookState")
        hooked("quickLookItems", e.quickLookItems, s.quickLookItems, hook: "quickLookState")
        if let want = e.cells {
            if let cells = s.cells {
                for (row, columns) in want.sorted(by: { $0.key < $1.key }) {
                    for (column, text) in columns.sorted(by: { $0.key < $1.key }) where cells[row]?[column] != text {
                        m.append("cells: '\(row)' [\(column)] expected '\(text)', got \(cells[row]?[column].map { "'\($0)'" } ?? "no such cell")")
                    }
                }
            } else {
                m.append(missingHook("cells", "cellText"))
            }
        }
        hooked("columnsChain", e.columnsChain, s.columnsChain, hook: "columnsChain")
        hooked("activeColumn", e.activeColumn, s.activeColumn, hook: "columnsChain")
        subset("thumbnailsContain", e.thumbnailsContain, s.thumbnails, hook: "thumbnailNames")
        subset("iconsVisibleContain", e.iconsVisibleContain, s.iconsVisible, hook: "iconsVisibleNames")
        if let want = e.pasteboardText, want != s.pasteboardText {
            m.append("pasteboardText: expected '\(want)', got \(s.pasteboardText.map { "'\($0)'" } ?? "no snapshot")")
        }
    }
}

extension ExpectationMatcher {
    static func phase3Mismatches(_ e: ScenarioFile.Expectation, _ s: ProbeSnapshot, into m: inout [String]) {
        func check<T: Equatable>(_ label: String, _ expected: T?, _ actual: T) {
            if let expected, expected != actual { m.append("\(label): expected \(expected), got \(actual)") }
        }
        check("searchState", e.searchState, s.searchState)
        if let want = e.resultCount {
            if let count = s.resultCount { check("resultCount", want, count) } else { m.append("resultCount: no search results are shown") }
        }
        check("rowPaths", e.rowPaths, s.rowPaths)
        check("notices", e.notices, s.notices)
        check("previewState", e.previewState, s.previewState)
        if let want = e.previewTextPrefix, !(s.previewText?.hasPrefix(want) ?? false) {
            m.append("previewTextPrefix: expected '\(want)', got \(s.previewText.map { "'\($0)'" } ?? "no text preview")")
        }
        check("sidebarSearches", e.sidebarSearches, s.sidebarSearches)
        check("windowStates", e.windowStates, s.windowStates)
        check("showHidden", e.showHidden, s.showHidden)
    }
}
