import Foundation

/// Settings › Shortcuts presets, import and export (P4-02), applied to `keyBindingOverrides` and `returnKey`.
/// `KeyBindingsController` (UI) picks the change up and updates the menus and key routing at once.
extension Settings {
    /// The preset the current keys are exactly (same triggers for every command), or nil once the user has edited
    /// them ("Custom"). The Return key setting doesn't count: it has its own control in General.
    public var keymapPreset: KeymapPreset? { KeymapPreset(matching: keyBindingOverrides) }

    /// Replaces every shortcut with `preset`'s and sets the Return key to go with it (Finder: Rename).
    public func applyKeymapPreset(_ preset: KeymapPreset) {
        keyBindingOverrides = preset.overrides
        returnKey = preset.returnKey
        keymapBase = preset
    }

    /// Settings › Shortcuts › Restore All Defaults: the built-in (Explorer) keys.
    public func restoreDefaultShortcuts() {
        keyBindingOverrides = .empty
        keymapBase = .explorer
    }

    /// Whether `command`'s keys differ from the base preset's (`keymapBase`), which is what per-row Reset restores.
    public func isShortcutModified(_ command: Command) -> Bool {
        !keyBindings.sameTriggers(as: KeyBindings(overrides: keymapBase.overrides), for: command)
    }

    /// Per-row Reset: `command` gets the base preset's keys back (see `KeyBindingOverrides.reset(_:to:)`).
    public func resetShortcut(_ command: Command) {
        keyBindingOverrides.reset(command, to: keymapBase.overrides)
    }

    /// The keymap file for the current keys and Return key setting (`KeymapDocument`), on the base preset.
    public func exportKeymap() -> Data { KeymapDocument.export(keyBindingOverrides, returnKey: returnKey, base: keymapBase) }

    /// Replaces the keys (and the Return key setting, when the file has one) with the keymap in `data`; returns the
    /// entries it skipped. On any error nothing changes.
    @discardableResult
    public func importKeymap(_ data: Data) throws(KeymapImportError) -> [KeymapWarning] {
        let (overrides, warnings) = try KeymapDocument.import(data)
        keyBindingOverrides = overrides
        keymapBase = KeymapDocument.base(in: data)
        if let returnKey = KeymapDocument.returnKey(in: data) { self.returnKey = returnKey }
        return warnings
    }
}
