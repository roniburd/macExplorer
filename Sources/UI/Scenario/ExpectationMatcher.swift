import Core
import Foundation

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
    var propertiesWindows = 0
    var windowCount = 1
    var fileSizes: [String: Int] = [:]       // requested paths that exist → st_size
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
}

enum ExpectationMatcher {
    static func requestedPaths(_ e: ScenarioFile.Expectation) -> [String] {
        (e.filesExist ?? []) + (e.filesAbsent ?? []) + Array((e.fileSizes ?? [:]).keys)
    }

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
        check("propertiesWindows", e.propertiesWindows, s.propertiesWindows)
        check("windowCount", e.windowCount, s.windowCount)
        for path in e.filesExist ?? [] where s.fileSizes[path] == nil { m.append("filesExist: '\(path)' is missing") }
        for path in e.filesAbsent ?? [] where s.fileSizes[path] != nil { m.append("filesAbsent: '\(path)' exists") }
        for (path, size) in (e.fileSizes ?? [:]).sorted(by: { $0.key < $1.key }) where s.fileSizes[path] != size {
            m.append("fileSizes: '\(path)' expected \(size) bytes, got \(s.fileSizes[path].map { String($0) } ?? "missing")")
        }
        return m
    }
}
