import Foundation

/// Edits used by Settings › Shortcuts. Each edit rewrites only the slot it touches; a slot that ends up equal to its
/// `KeyMap` default is dropped, and an empty entry is removed, so "has an entry" means "differs from the defaults".
/// Fixed commands and triggers that fail `KeyBindings.validate` are ignored.
extension KeyBindingOverrides {
    private struct Slots {
        var primary: KeyChord?
        var alternates: [KeyChord]
        var mouse: [MouseButton]
    }

    public mutating func setPrimary(_ chord: KeyChord?, for command: Command) {
        if let chord, KeyBindings.validate(.key(chord), as: .primary) != nil { return }
        update(command) { $0.primary = chord }
    }

    public mutating func removeAlternate(_ chord: KeyChord, from command: Command) {
        update(command) { $0.alternates.removeAll { $0 == chord } }
    }

    public mutating func removeMouse(_ button: MouseButton, from command: Command) {
        update(command) { $0.mouse.removeAll { $0 == button } }
    }

    /// Gives `trigger` to `command`'s `slot`, first removing it from every other slot that holds it (including the
    /// same command's other slot).
    public mutating func reassign(_ trigger: Trigger, to command: Command, as slot: KeyBindings.Slot) {
        guard !KeyBindings.fixedCommands.contains(command), KeyBindings.validate(trigger, as: slot) == nil else { return }
        for use in KeyBindings(overrides: self).uses(of: trigger) where use != KeyBindings.Use(command: command, slot: slot) {
            remove(trigger, from: use)
        }
        update(command) { slots in
            switch (slot, trigger) {
            case (.primary, .key(let chord)): slots.primary = chord
            case (.alternate, .key(let chord)): if !slots.alternates.contains(chord) { slots.alternates.append(chord) }
            case (.mouse, .mouse(let button)):
                if !slots.mouse.contains(button) { slots.mouse.append(button); slots.mouse.sort() }
            default: break
            }
        }
    }

    /// Restores `command`'s defaults. Like `reassign`, each restored trigger is first taken from any other command
    /// that holds it now (e.g. a ⌘[ given to Up after Back's was reassigned), so no two commands end up sharing it.
    public mutating func reset(_ command: Command) {
        guard commands[command] != nil else { return }
        commands[command] = nil
        guard !KeyBindings.fixedCommands.contains(command) else { return }
        let restored = [KeyMap.primary(command)].compactMap { $0 }.map(Trigger.key)
            + KeyMap.alternates(command).map(Trigger.key) + KeyMap.defaultMouse(command).map(Trigger.mouse)
        for trigger in restored {
            for use in KeyBindings(overrides: self).uses(of: trigger) where use.command != command {
                remove(trigger, from: use)
            }
        }
    }

    private mutating func remove(_ trigger: Trigger, from use: KeyBindings.Use) {
        switch (use.slot, trigger) {
        case (.primary, _): update(use.command) { $0.primary = nil }
        case (.alternate, .key(let chord)): removeAlternate(chord, from: use.command)
        case (.mouse, .mouse(let button)): removeMouse(button, from: use.command)
        default: break
        }
    }

    private mutating func update(_ command: Command, _ change: (inout Slots) -> Void) {
        guard !KeyBindings.fixedCommands.contains(command) else { return }
        let current = KeyBindings(overrides: self)
        var slots = Slots(primary: current.primary(command), alternates: current.alternates(command), mouse: current.mouse(command))
        change(&slots)
        var entry = Entry()
        if slots.primary != KeyMap.primary(command) { entry.primary = slots.primary.map(PrimaryOverride.chord) ?? .unbound }
        if slots.alternates != KeyMap.alternates(command) { entry.alternates = slots.alternates }
        if slots.mouse != KeyMap.defaultMouse(command) { entry.mouse = slots.mouse }
        commands[command] = entry.isEmpty ? nil : entry
    }
}
