import Foundation

public enum BindingRejection: Sendable, Equatable {
    /// ⌘Q, ⌘H, ⌥⌘H, ⌘M, ⌘, ⌃⌘S, ⌃⌘F, ⌘? (⇧⌘/) and ⌘` belong to fixed menu items (`KeyBindings.fixedMenuChords`)
    /// and window cycling; Tab, ⇧Tab and Esc to focus and cancel.
    case reserved
    /// A primary with no ⌘ or ⌃ that isn't a function key, other than ⌥ with a key that doesn't type (arrows, ↩, ⌤,
    /// ⌫, Del). So: a character or space with any mix of ⌥/⇧ (⌥L types @ on a German layout), or a bare/⇧ Return,
    /// Enter, ⌫, Del or arrow. Menu key equivalents are matched before the field editor sees the key, so it would
    /// fire while typing or editing a name or path instead of reaching the text.
    case editsTextAsPrimary
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
    /// Key equivalents of the menu items that aren't commands, keyed by their English title. `MainMenuBuilder` takes
    /// them from here, so the reserved set can't drift from the menu. Help's ⇧⌘/ is shown as ⌘?.
    public static let fixedMenuChords: [String: KeyChord] = [
        "Settings…": KeyChord(.character(","), .command),
        "Hide MacExplorer": KeyChord(.character("h"), .command),
        "Hide Others": KeyChord(.character("h"), [.option, .command]),
        "Quit MacExplorer": KeyChord(.character("q"), .command),
        "Show Sidebar": KeyChord(.character("s"), [.control, .command]),
        "Enter Full Screen": KeyChord(.character("f"), [.control, .command]),
        "Minimize": KeyChord(.character("m"), .command),
        "MacExplorer Help": KeyChord(.character("/"), [.shift, .command]),
    ]
    /// The fixed menu items' chords, ⌘` (cycle windows), and Tab, ⇧Tab and Esc.
    public static let reservedChords: Set<KeyChord> = Set(fixedMenuChords.values).union([
        KeyChord(.character("`"), .command), KeyChord(.tab), KeyChord(.tab, .shift), KeyChord(.escape),
    ])

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
            // Stored alternates go through the same check as stored primaries, so hand-edited or stale data can't
            // take Tab, ⇧Tab, Esc or a menu chord away from its owner. (Stored mouse lists need no filtering: they
            // can only hold mouse buttons, and every mouse button is valid in the mouse slot.)
            // Repeats in hand-edited lists are dropped (first kept), so each trigger shows once in Settings.
            let alternates = entry?.alternates.map { Self.unique($0.filter { Self.validate(.key($0), as: .alternate) == nil }) }
                ?? KeyMap.alternates(command)
            alternateLists[command] = alternates
            let mouse = entry?.mouse.map(Self.unique) ?? KeyMap.defaultMouse(command)
            mouseLists[command] = mouse
            for chord in alternates where alternateTable[chord] == nil { alternateTable[chord] = command }
            for button in mouse where mouseTable[button] == nil { mouseTable[button] = command }
        }
        self.primaries = primaries
        self.alternateLists = alternateLists
        self.mouseLists = mouseLists
        self.alternateTable = alternateTable
        self.mouseTable = mouseTable
        // A primary collides when it is a text-system chord, or a chord that types (only a default can be one, e.g.
        // ⌥P → "π": `validate` rejects typing chords as user primaries).
        self.collidesWithTextEditing = Set(primaries.compactMap { command, chord in
            KeyMap.textEditingChords.contains(chord) || Self.validate(.key(chord), as: .primary) == .editsTextAsPrimary
                ? command : nil
        })
    }

    public static func == (a: KeyBindings, b: KeyBindings) -> Bool { a.overrides == b.overrides }

    private static func unique<T: Hashable>(_ list: [T]) -> [T] {
        var seen: Set<T> = []
        return list.filter { seen.insert($0).inserted }
    }

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

    /// `validate` for `command`'s own slot: a command's built-in primary is always accepted there, even a typing
    /// chord like ⌥P (QA polish: rebinding Show Preview Pane away and back to ⌥P must work). It still collides
    /// with text editing (`collidesWithTextEditing`), so the field editor keeps the key while typing.
    public static func validate(_ trigger: Trigger, as slot: Slot, for command: Command) -> BindingRejection? {
        if slot == .primary, case .key(let chord) = trigger, chord == KeyMap.primary(command) { return nil }
        return validate(trigger, as: slot)
    }

    public static func validate(_ trigger: Trigger, as slot: Slot) -> BindingRejection? {
        switch (trigger, slot) {
        case (.mouse, .mouse): return nil
        case (.mouse, _), (.key, .mouse): return .wrongSlot
        case (.key(let chord), _):
            if reservedChords.contains(chord) { return .reserved }
            guard slot == .primary, chord.modifiers.isDisjoint(with: [.command, .control]) else { return nil }
            switch chord.key {
            case .function: return nil
            case .character, .space: return .editsTextAsPrimary
            default: return chord.modifiers.contains(.option) ? nil : .editsTextAsPrimary
            }
        }
    }
}
