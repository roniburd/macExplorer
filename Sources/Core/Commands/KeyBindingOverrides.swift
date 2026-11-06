import Foundation

/// The user's changes to the built-in key table (`KeyMap`). Sparse: a command with no entry uses its defaults, and
/// each nil field keeps that slot's default. Stored under Settings key "keyBindings".
public struct KeyBindingOverrides: Sendable, Equatable {
    public enum PrimaryOverride: Sendable, Equatable {
        case unbound
        case chord(KeyChord)
    }

    public struct Entry: Sendable, Equatable {
        public var primary: PrimaryOverride?
        public var alternates: [KeyChord]?
        public var mouse: [MouseButton]?
        public init(primary: PrimaryOverride? = nil, alternates: [KeyChord]? = nil, mouse: [MouseButton]? = nil) {
            self.primary = primary
            self.alternates = alternates
            self.mouse = mouse
        }
        public var isEmpty: Bool { primary == nil && alternates == nil && mouse == nil }
    }

    public var commands: [Command: Entry]
    public init(commands: [Command: Entry] = [:]) { self.commands = commands }
    public static let empty = KeyBindingOverrides()
}

/// JSON: {"back": {"primary": "opt+cmd+b", "alternates": ["delete"], "mouse": ["mouse4"]}}. "primary": "" = unbound.
/// Decoding drops what it can't read (unknown command, bad chord, wrong type) and keeps the rest.
extension KeyBindingOverrides: Codable {
    private struct Raw: Codable {
        var primary: String?
        var alternates: [String]?
        var mouse: [String]?

        init(primary: String?, alternates: [String]?, mouse: [String]?) {
            self.primary = primary
            self.alternates = alternates
            self.mouse = mouse
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            primary = try? c.decodeIfPresent(String.self, forKey: .primary)
            alternates = try? c.decodeIfPresent([String].self, forKey: .alternates)
            mouse = try? c.decodeIfPresent([String].self, forKey: .mouse)
        }
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode([String: Raw].self)
        var commands: [Command: Entry] = [:]
        for (name, value) in raw {
            guard let command = Command(rawValue: name) else { continue }
            var entry = Entry()
            if let text = value.primary {
                entry.primary = text.isEmpty ? .unbound : KeyChord(parsing: text).map(PrimaryOverride.chord)
            }
            entry.alternates = value.alternates?.compactMap(KeyChord.init(parsing:))
            entry.mouse = value.mouse?.compactMap(MouseButton.init(parsing:))
            if !entry.isEmpty { commands[command] = entry }
        }
        self.commands = commands
    }

    public func encode(to encoder: any Encoder) throws {
        var raw: [String: Raw] = [:]
        for (command, entry) in commands {
            let primary: String? = switch entry.primary {
            case nil: nil
            case .unbound?: ""
            case .chord(let chord)?: chord.description
            }
            raw[command.rawValue] = Raw(primary: primary, alternates: entry.alternates?.map(\.description),
                                        mouse: entry.mouse?.map(\.description))
        }
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}
