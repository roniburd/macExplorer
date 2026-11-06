import Foundation

public enum BindingRejection: Sendable, Equatable {
    /// ⌘Q, ⌘H, ⌥⌘H, ⌘M, ⌘, and ⌘` belong to the app and window menus; Tab, ⇧Tab and Esc to focus and cancel.
    case reserved
    /// A plain character or space (no ⌘, ⌃ or ⌥) as a menu shortcut would fire while typing a name.
    case typesTextAsPrimary
    /// A mouse button in a key slot, or a key in the mouse slot.
    case wrongSlot
}

/// The resolved key table: `KeyMap` defaults plus the user's `KeyBindingOverrides`.
public struct KeyBindings: Sendable, Equatable {
    public enum Slot: Sendable, Hashable { case primary, alternate, mouse }

    public struct Use: Sendable, Hashable {
        public let command: Command
        public let slot: Slot
        public init(command: Command, slot: Slot) {
            self.command = command
            self.slot = slot
        }
    }

    public static let defaults = KeyBindings(overrides: .empty)
    /// Tab / ⇧Tab (focus cycle) and Esc stay as they are; Settings shows them but can't edit them.
    public static let fixedCommands: Set<Command> = [.cycleFocusForward, .cycleFocusBackward, .cancelOperation]
    public static let reservedChords: Set<KeyChord> = [
        KeyChord(.character("q"), .command), KeyChord(.character("h"), .command),
        KeyChord(.character("h"), [.option, .command]), KeyChord(.character("m"), .command),
        KeyChord(.character(","), .command), KeyChord(.character("`"), .command),
        KeyChord(.tab), KeyChord(.tab, .shift), KeyChord(.escape),
    ]

    public let overrides: KeyBindingOverrides
    public let collidesWithTextEditing: Set<Command>
    private let primaries: [Command: KeyChord]
    private let alternateLists: [Command: [KeyChord]]
    private let mouseLists: [Command: [MouseButton]]
    private let alternateTable: [KeyChord: Command]
    private let mouseTable: [MouseButton: Command]

    public init(overrides: KeyBindingOverrides) {
        self.overrides = overrides
        var primaries: [Command: KeyChord] = [:]
        var alternateLists: [Command: [KeyChord]] = [:]
        var mouseLists: [Command: [MouseButton]] = [:]
        var alternateTable: [KeyChord: Command] = [:]
        var mouseTable: [MouseButton: Command] = [:]
        for command in Command.allCases {
            let entry = Self.fixedCommands.contains(command) ? nil : overrides.commands[command]
            let primary: KeyChord? = switch entry?.primary {
            case nil: KeyMap.primary(command)
            case .unbound?: nil
            case .chord(let chord)?: Self.validate(.key(chord), as: .primary) == nil ? chord : KeyMap.primary(command)
            }
            primaries[command] = primary
            let alternates = entry?.alternates ?? KeyMap.alternates(command)
            alternateLists[command] = alternates
            let mouse = entry?.mouse ?? KeyMap.defaultMouse(command)
            mouseLists[command] = mouse
            for chord in alternates where alternateTable[chord] == nil { alternateTable[chord] = command }
            for button in mouse where mouseTable[button] == nil { mouseTable[button] = command }
        }
        self.primaries = primaries
        self.alternateLists = alternateLists
        self.mouseLists = mouseLists
        self.alternateTable = alternateTable
        self.mouseTable = mouseTable
        self.collidesWithTextEditing = Set(primaries.compactMap { KeyMap.textEditingChords.contains($0.value) ? $0.key : nil })
    }

    public static func == (a: KeyBindings, b: KeyBindings) -> Bool { a.overrides == b.overrides }

    public func primary(_ command: Command) -> KeyChord? { primaries[command] }
    public func alternates(_ command: Command) -> [KeyChord] { alternateLists[command] ?? [] }
    public func mouse(_ command: Command) -> [MouseButton] { mouseLists[command] ?? [] }
    public func alternateCommand(for chord: KeyChord) -> Command? { alternateTable[chord] }
    public func command(for button: MouseButton) -> Command? { mouseTable[button] }

    /// Every command slot that currently holds `trigger`, in `Command.allCases` order.
    public func uses(of trigger: Trigger) -> [Use] {
        Command.allCases.flatMap { command -> [Use] in
            switch trigger {
            case .key(let chord):
                var uses: [Use] = []
                if primary(command) == chord { uses.append(Use(command: command, slot: .primary)) }
                if alternates(command).contains(chord) { uses.append(Use(command: command, slot: .alternate)) }
                return uses
            case .mouse(let button):
                return mouse(command).contains(button) ? [Use(command: command, slot: .mouse)] : []
            }
        }
    }

    public static func validate(_ trigger: Trigger, as slot: Slot) -> BindingRejection? {
        switch (trigger, slot) {
        case (.mouse, .mouse): return nil
        case (.mouse, _), (.key, .mouse): return .wrongSlot
        case (.key(let chord), _):
            if reservedChords.contains(chord) { return .reserved }
            if slot == .primary, chord.modifiers.isDisjoint(with: [.command, .control, .option]) {
                switch chord.key {
                case .character, .space: return .typesTextAsPrimary
                default: break
                }
            }
            return nil
        }
    }
}
