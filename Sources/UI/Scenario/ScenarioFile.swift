import Core
import Foundation

/// §3.14 schema (field names and types exactly as in the contract) plus additive optional fields
/// (Contract note C6): Fixture.modes, Step.command, Step.answerAlert, Expectation.rowCount/editingAddress/
/// viewMode/sheetPresent/propertiesWindows/windowCount/fileSizes.
struct ScenarioFile: Codable {
    struct Fixture: Codable {
        var files: [String]
        var dirs: [String]
        var hidden: [String]?
        var sizes: [String: Int]?
        var modes: [String: String]?          // additive: octal mode applied after creation, deepest first
    }
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

        var actions: [String] {
            let named: [(String, Bool)] = [
                ("key", key != nil), ("type", type != nil), ("menu", menu != nil), ("command", command != nil),
                ("click", click != nil), ("doubleClick", doubleClick != nil), ("rightClick", rightClick != nil),
                ("chooseMenuItem", chooseMenuItem != nil), ("drop", drop != nil), ("answerConflict", answerConflict != nil),
                ("answerAlert", answerAlert != nil), ("waitFor", waitFor != nil), ("expect", expect != nil), ("sleepMs", sleepMs != nil),
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
    }
    var name: String
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
            }
        }
    }

    static let modifierNames: Set<String> = ["cmd", "shift", "opt", "ctrl"]
    static let dropChoices: Set<String> = ["copy", "move", "alias", "cancel"]

    func validate() throws(ValidationError) {
        let fixturePaths = fixture.files + fixture.dirs + (fixture.hidden ?? [])
            + Array((fixture.sizes ?? [:]).keys) + Array((fixture.modes ?? [:]).keys)
        for path in fixturePaths where !ScenarioPath.isSafeRelative(path) { throw .unsafePath(path) }
        for (path, mode) in fixture.modes ?? [:] where mode.count > 4 || UInt16(mode, radix: 8) == nil { throw .badMode(path, mode) }
        for (index, step) in steps.enumerated() {
            let actions = step.actions
            guard actions.count == 1 else { throw .actionCount(step: index, actions: actions) }
            if let key = step.key, KeyChord(parsing: key).flatMap(KeySynth.spec(for:)) == nil { throw .badKey(step: index, key) }
            if let action = step.answerConflict, ConflictAction(rawValue: action) == nil { throw .badConflictAction(step: index, action) }
            if let choice = step.drop?.choose, !Self.dropChoices.contains(choice) { throw .badDropChoice(step: index, choice) }
            if let command = step.command, Command(rawValue: command) == nil { throw .badCommand(step: index, command) }
            for modifier in step.modifiers ?? [] where !Self.modifierNames.contains(modifier) { throw .badModifier(step: index, modifier) }
            if let text = step.type, text.hasPrefix("/") || text.hasPrefix("~") { throw .unsafeTypedPath(step: index, text) }
            let dropPaths = step.drop.map { $0.sources + [$0.onto] } ?? []
            let paths = dropPaths + (step.waitFor.map(ExpectationMatcher.requestedPaths) ?? [])
                + (step.expect.map(ExpectationMatcher.requestedPaths) ?? [])
            for path in paths where !ScenarioPath.isSafeRelative(path) { throw .unsafePath(path) }
        }
    }

    static func load(_ data: Data) throws -> ScenarioFile {
        let file = try JSONDecoder().decode(ScenarioFile.self, from: data)
        try file.validate()
        return file
    }
}

enum ScenarioPath {
    /// Non-empty, relative, no "~", and no empty, "." or ".." components.
    static func isSafeRelative(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
