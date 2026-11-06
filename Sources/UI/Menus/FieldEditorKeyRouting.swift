import AppKit
import Core

/// §5.6 key routing 1–3: while a field editor (address bar, inline rename, search) is first responder, the primaries
/// in `KeyBindings.collidesWithTextEditing` (by default ⌘↑, ⌘↓, ⌘⌫, ⌥⌘⌫, ⌘[, ⌘], F2, ⌘D; see `KeyMap.textEditingChords`) belong to the text. Disabling their menu
/// items (MenuValidation) is not enough: AppKit swallows the key equivalent of a disabled item, so the field editor
/// never sees ⌘↑ or ⌘⌫ (verified in the P1-41 colliding-keys scenario). MacxApplication.sendEvent therefore hands
/// those keys to the field editor before the menu is consulted.
@MainActor enum FieldEditorKeyRouting {
    /// The colliding command whose current primary `event` is, if any.
    static func collidingCommand(for event: NSEvent) -> Command? {
        guard event.type == .keyDown, let chord = KeyEventTranslator.chord(for: event) else { return nil }
        let bindings = ActiveKeyBindings.current
        return bindings.collidesWithTextEditing.first { bindings.primary($0) == chord }
    }

    /// Delivers a colliding primary straight to `window`'s field editor. Returns true if it did.
    static func route(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor,
              collidingCommand(for: event) != nil else { return false }
        editor.keyDown(with: event)
        return true
    }
}
