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
        if let chord, KeyBindings.validate(.key(chord), as: .primary, for: command) != nil { return }
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
        guard !KeyBindings.fixedCommands.contains(command), KeyBindings.validate(trigger, as: slot, for: command) == nil else { return }
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

    /// Restores `command`'s keys in `base` (a preset's overrides; `.empty` = the `KeyMap` defaults). Like `reassign`,
    /// each restored trigger is first taken from any other command that holds it now (e.g. a ⌘[ given to Up after
    /// Back's was reassigned), so no two commands end up sharing it.
    public mutating func reset(_ command: Command, to base: KeyBindingOverrides = .empty) {
        let baseBindings = KeyBindings(overrides: base)
        guard !KeyBindings(overrides: self).sameTriggers(as: baseBindings, for: command) else { return }
        commands[command] = base.commands[command]
        guard !KeyBindings.fixedCommands.contains(command) else { return }
        let restored = [baseBindings.primary(command)].compactMap { $0 }.map(Trigger.key)
            + baseBindings.alternates(command).map(Trigger.key) + baseBindings.mouse(command).map(Trigger.mouse)
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
        guard !KeyBindings.fixedCommands.contains(command), CommandAvailability.isShipped(command) else { return }
        let current = KeyBindings(overrides: self)
        var slots = Slots(primary: current.primary(command), alternates: current.alternates(command), mouse: current.mouse(command))
        change(&slots)
        commands[command] = Self.normalizedEntry(command, primary: slots.primary, alternates: slots.alternates, mouse: slots.mouse)
    }

    /// The entry that gives `command` these slots: only the slots that differ from the `KeyMap` defaults, or nil
    /// when none does.
    static func normalizedEntry(_ command: Command, primary: KeyChord?, alternates: [KeyChord], mouse: [MouseButton]) -> Entry? {
        var entry = Entry()
        if primary != KeyMap.primary(command) { entry.primary = primary.map(PrimaryOverride.chord) ?? .unbound }
        if alternates != KeyMap.alternates(command) { entry.alternates = alternates }
        if mouse != KeyMap.defaultMouse(command) { entry.mouse = mouse }
        return entry.isEmpty ? nil : entry
    }
}
