import Foundation

/// A problem with a key table that Settings › Shortcuts would never produce (only an imported or hand-edited one
/// can have it). Core reports these as values; the UI words them.
public enum KeymapIssue: Sendable, Equatable {
    /// Two or more commands hold `trigger` (in any slot). `commands` is sorted by raw value.
    case conflict(trigger: Trigger, commands: [Command])
    /// `chord` is reserved by macOS or a fixed MacExplorer menu item (`KeyBindings.reservedChords`).
    case reserved(chord: KeyChord, command: Command)
    /// `chord` would type or edit text if it were a menu key (`BindingRejection.editsTextAsPrimary`).
    case notAPrimary(chord: KeyChord, command: Command)
}

public enum KeymapValidator {
    /// Every issue in `overrides`: conflicts sorted by trigger text, then each command's reserved or not-a-primary
    /// chords sorted by command (its primary before its alternates). Empty for anything Settings › Shortcuts
    /// writes. Fixed and unshipped commands are skipped (their entries are never used).
    public static func issues(_ overrides: KeyBindingOverrides) -> [KeymapIssue] {
        var perCommand: [KeymapIssue] = []
        for (command, entry) in overrides.commands.sorted(by: { $0.key.rawValue < $1.key.rawValue })
        where !KeyBindings.fixedCommands.contains(command) && CommandAvailability.isShipped(command) {
            var found: [KeymapIssue] = []
            if case .chord(let chord)? = entry.primary {
                switch KeyBindings.validate(.key(chord), as: .primary, for: command) {
                case .reserved?: found.append(.reserved(chord: chord, command: command))
                case .editsTextAsPrimary?: found.append(.notAPrimary(chord: chord, command: command))
                case .wrongSlot?, nil: break
                }
            }
            for chord in entry.alternates ?? [] where KeyBindings.validate(.key(chord), as: .alternate) == .reserved {
                found.append(.reserved(chord: chord, command: command))
            }
            for issue in found where !perCommand.contains(issue) { perCommand.append(issue) }
        }

        let bindings = KeyBindings(overrides: overrides)
        var holders: [Trigger: Set<Command>] = [:]
        for command in Command.allCases {
            let triggers = [bindings.primary(command)].compactMap { $0 }.map(Trigger.key)
                + bindings.alternates(command).map(Trigger.key) + bindings.mouse(command).map(Trigger.mouse)
            for trigger in triggers { holders[trigger, default: []].insert(command) }
        }
        let conflicts = holders.filter { $0.value.count > 1 }
            .sorted { $0.key.text < $1.key.text }
            .map { KeymapIssue.conflict(trigger: $0.key, commands: $0.value.sorted { $0.rawValue < $1.rawValue }) }
        return conflicts + perCommand
    }
}

extension Trigger {
    /// The stored text form: a chord's ("shift+cmd+n") or a mouse button's ("mouse4").
    public var text: String {
        switch self {
        case .key(let chord): chord.description
        case .mouse(let button): button.description
        }
    }
}
