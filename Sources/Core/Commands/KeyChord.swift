import Foundation

public struct KeyModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let option  = KeyModifiers(rawValue: 1 << 1)
    public static let control = KeyModifiers(rawValue: 1 << 2)
    public static let shift   = KeyModifiers(rawValue: 1 << 3)
}

public enum Key: Hashable, Sendable {
    case character(String)        // lowercased base character with no modifiers applied
                                  // (NSEvent.characters(byApplyingModifiers: [])), e.g. "c", "[", "." for ⌘⇧.
    case up, down, left, right
    case returnKey, enter, tab, escape, space
    case backspace                // ⌫ (delete backward)
    case forwardDelete            // Del / fn⌫
    case function(Int)            // F1…F20
}

/// A key plus modifiers. `description` is the canonical text form ("ctrl+opt+shift+cmd+<key>", e.g. "shift+cmd+n",
/// "opt+cmd+delete", "shift+fn+delete", "F2"); it round-trips through `init?(parsing:)`.
public struct KeyChord: Hashable, Sendable, CustomStringConvertible {
    public var key: Key
    public var modifiers: KeyModifiers

    public init(_ key: Key, _ modifiers: KeyModifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    /// Parses "cmd+shift+n", "F2", "opt+left", "ctrl+c", "fn+delete" (= forwardDelete), "return", "esc".
    /// Modifiers (any order, case-insensitive): cmd/command, shift, opt/option/alt, ctrl/control, fn.
    /// Keys: a single character, up/down/left/right, return, enter, tab, esc/escape, space, delete/backspace (⌫),
    /// del/forwarddelete/fwddelete (Del), plus (+), F1–F20. "fn" is accepted only with delete (→ Del) and F-keys.
    public init?(parsing text: String) {
        var tokens = text.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        let keyToken: String
        if tokens.count >= 2, tokens[tokens.count - 1].isEmpty, tokens[tokens.count - 2].isEmpty {
            keyToken = "+"                                   // "cmd++" or "+" (split gives ["", ""])
            tokens.removeLast(2)
        } else {
            keyToken = tokens.removeLast()
        }
        var modifiers: KeyModifiers = []
        var fn = false
        for token in tokens {
            switch token.lowercased() {
            case "cmd", "command", "⌘": modifiers.insert(.command)
            case "shift", "⇧": modifiers.insert(.shift)
            case "opt", "option", "alt", "⌥": modifiers.insert(.option)
            case "ctrl", "control", "⌃": modifiers.insert(.control)
            case "fn": fn = true
            default: return nil
            }
        }
        guard var key = Self.key(named: keyToken) else { return nil }
        if fn {
            switch key {
            case .backspace, .forwardDelete: key = .forwardDelete
            case .function: break
            default: return nil
            }
        }
        self.init(key, modifiers)
    }

    public var description: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        parts.append(Self.name(of: key))
        return parts.joined(separator: "+")
    }

    private static func key(named token: String) -> Key? {
        if token.count == 1 {
            return token == " " ? .space : .character(token.lowercased())
        }
        let lower = token.lowercased()
        switch lower {
        case "up", "↑": return .up
        case "down", "↓": return .down
        case "left", "←": return .left
        case "right", "→": return .right
        case "return", "ret", "↩": return .returnKey
        case "enter", "⌤": return .enter
        case "tab", "⇥": return .tab
        case "esc", "escape", "⎋": return .escape
        case "space": return .space
        case "delete", "backspace", "⌫": return .backspace
        case "del", "forwarddelete", "fwddelete", "⌦": return .forwardDelete
        case "plus": return .character("+")
        default:
            guard lower.hasPrefix("f"), let n = Int(lower.dropFirst()), (1...20).contains(n),
                  lower.dropFirst().allSatisfy(\.isASCII) else { return nil }
            return .function(n)
        }
    }

    private static func name(of key: Key) -> String {
        switch key {
        case .character(let c): c == " " ? "space" : c
        case .up: "up"
        case .down: "down"
        case .left: "left"
        case .right: "right"
        case .returnKey: "return"
        case .enter: "enter"
        case .tab: "tab"
        case .escape: "esc"
        case .space: "space"
        case .backspace: "delete"
        case .forwardDelete: "fn+delete"
        case .function(let n): "F\(n)"
        }
    }
}

/// Stored as the canonical text form ("opt+cmd+delete").
extension KeyChord: Codable {
    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let chord = KeyChord(parsing: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad key chord '\(text)'"))
        }
        self = chord
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
