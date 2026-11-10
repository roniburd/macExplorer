import Foundation

public enum KeymapWarning: Sendable, Equatable {
    /// A command this version doesn't have (or hasn't shipped yet), e.g. from a newer MacExplorer. Skipped.
    case unknownCommand(String)
    /// Tab, ⇧Tab and Esc can't be rebound (`KeyBindings.fixedCommands`). Skipped.
    case fixedCommand(Command)
}

public enum KeymapImportError: Error, Sendable, Equatable {
    /// Not JSON, or not a MacExplorer keymap (`format`, `version` or `bindings` missing or of the wrong type).
    case notAKeymap
    case unsupportedVersion(Int)
    case unknownBase(String)
    /// A primary, alternate or mouse button `text` that doesn't parse (or an entry that isn't an object).
    case invalidChord(command: String, text: String)
    /// The keymap reads fine but can't be used as is (`KeymapValidator`).
    case issues([KeymapIssue])
}

/// The keymap file Settings › Shortcuts imports and exports:
///
///     {
///       "format" : "macexplorer-keymap",
///       "version" : 1,
///       "base" : "finder",
///       "bindings" : {
///         "duplicate" : { "primary" : null },
///         "refresh" : { "alternates" : [ "ctrl+r" ] },
///         "up" : { "mouse" : [ "mouse6" ] }
///       }
///     }
///
/// `base` is a `KeymapPreset`; each binding replaces only the slots it lists (`primary`: a chord, or null / "" for
/// none; `alternates` and `mouse`: lists), and every other slot keeps the base's value. Chords use the
/// Settings storage text form (`KeyChord.description`; `KeyChord(parsing:)` also takes "cmd+shift+n" orders and
/// aliases such as "backspace" and "fwddelete").
public enum KeymapDocument {
    public static let format = "macexplorer-keymap"
    public static let version = 1

    /// `overrides` as a document on the preset it differs least from (Explorer on a tie), listing only the changed
    /// slots. Keys sorted, pretty-printed.
    public static func export(_ overrides: KeyBindingOverrides) -> Data {
        let current = KeyBindings(overrides: overrides)
        let diffs = KeymapPreset.allCases.map { ($0, bindings(current, relativeTo: $0)) }
        let (base, entries) = diffs.min { $0.1.count < $1.1.count } ?? (.explorer, [:])
        let root: [String: Any] = ["format": format, "version": version, "base": base.rawValue, "bindings": entries]
        // Plain string/number/array/dictionary/NSNull values only, so serialization can't fail.
        return (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]))
            ?? Data()
    }

    /// The overrides `data` describes (relative to `KeyMap`, ready for `settings.keyBindingOverrides`), plus
    /// warnings for the entries it skipped. Throws when the file isn't a keymap, has an unreadable trigger, or
    /// has conflicts, reserved chords or typing chords as primaries.
    public static func `import`(_ data: Data) throws(KeymapImportError) -> (KeyBindingOverrides, [KeymapWarning]) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              root["format"] as? String == format, let fileVersion = integer(root["version"]) else { throw .notAKeymap }
        guard fileVersion == version else { throw .unsupportedVersion(fileVersion) }
        let baseName = root["base"] as? String ?? KeymapPreset.explorer.rawValue
        guard let base = KeymapPreset(rawValue: baseName) else { throw .unknownBase(baseName) }
        guard let entries = (root["bindings"] ?? [String: Any]()) as? [String: Any] else { throw .notAKeymap }

        var overrides = base.overrides
        let baseBindings = KeyBindings(overrides: overrides)
        var warnings: [KeymapWarning] = []
        for name in entries.keys.sorted() {
            guard let command = Command(rawValue: name), CommandAvailability.isShipped(command) else {
                warnings.append(.unknownCommand(name)); continue
            }
            guard !KeyBindings.fixedCommands.contains(command) else { warnings.append(.fixedCommand(command)); continue }
            let value = entries[name] as Any
            guard let entry = value as? [String: Any] else { throw .invalidChord(command: name, text: text(value)) }
            var primary = baseBindings.primary(command)
            if let raw = entry["primary"] {
                if raw is NSNull || raw as? String == "" {
                    primary = nil
                } else if let s = raw as? String, let chord = KeyChord(parsing: s) {
                    primary = chord
                } else {
                    throw .invalidChord(command: name, text: text(raw))
                }
            }
            let alternates = try list(entry["alternates"], command: name, parse: KeyChord.init(parsing:))
                ?? baseBindings.alternates(command)
            let mouse = try list(entry["mouse"], command: name, parse: MouseButton.init(parsing:))?.sorted()
                ?? baseBindings.mouse(command)
            overrides.commands[command] = KeyBindingOverrides.normalizedEntry(command, primary: primary,
                                                                               alternates: unique(alternates), mouse: unique(mouse))
        }
        let issues = KeymapValidator.issues(overrides)
        guard issues.isEmpty else { throw .issues(issues) }
        return (overrides, warnings)
    }

    /// Per command, the slots of `current` that differ from `preset`'s (nil primary → NSNull).
    private static func bindings(_ current: KeyBindings, relativeTo preset: KeymapPreset) -> [String: [String: Any]] {
        let base = KeyBindings(overrides: preset.overrides)
        var result: [String: [String: Any]] = [:]
        for command in Command.allCases
        where CommandAvailability.isShipped(command) && !KeyBindings.fixedCommands.contains(command) {
            var slots: [String: Any] = [:]
            if current.primary(command) != base.primary(command) {
                slots["primary"] = current.primary(command).map { $0.description as Any } ?? NSNull()
            }
            if current.alternates(command) != base.alternates(command) {
                slots["alternates"] = current.alternates(command).map(\.description)
            }
            if current.mouse(command) != base.mouse(command) { slots["mouse"] = current.mouse(command).map(\.description) }
            if !slots.isEmpty { result[command.rawValue] = slots }
        }
        return result
    }

    private static func list<T>(_ raw: Any?, command: String, parse: (String) -> T?) throws(KeymapImportError) -> [T]? {
        guard let raw else { return nil }
        guard let items = raw as? [Any] else { throw .invalidChord(command: command, text: text(raw)) }
        var result: [T] = []
        for item in items {
            guard let s = item as? String, let value = parse(s) else { throw .invalidChord(command: command, text: text(item)) }
            result.append(value)
        }
        return result
    }

    private static func unique<T: Hashable>(_ list: [T]) -> [T] {
        var seen: Set<T> = []
        return list.filter { seen.insert($0).inserted }
    }

    /// A JSON integer (not a Bool, not a fraction).
    private static func integer(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.intValue
        return NSNumber(value: value) == number ? value : nil
    }

    private static func text(_ raw: Any) -> String {
        if let s = raw as? String { return s }
        if let n = raw as? NSNumber { return n.stringValue }
        if raw is NSNull { return "null" }
        return String(describing: raw)
    }
}
