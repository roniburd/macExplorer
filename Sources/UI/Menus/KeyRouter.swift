import AppKit
import Core

/// Alternate keys (§5.6 key routing step 4) for the content views' and sidebar's `keyDown`. Primaries are menu key
/// equivalents and never come through here; text fields never call it.
@MainActor enum KeyRouter {
    /// Content/sidebar keyDown: alternates → NSApp.sendAction(Selector(command.selectorName), to: nil, from: view).
    /// Returns true if handled.
    ///
    /// The action goes to the first responder up the chain from `view` that implements it (so it reaches the view's
    /// own pane even while the app is inactive and has no key window), else nil-targeted to the app.
    ///
    /// `typeSelectActive`: the list's type-select buffer is collecting, so plain Space belongs to it (Review Focus 1).
    static func handle(_ event: NSEvent, focus: FocusContext, returnKey: ReturnKeyBehavior, from view: NSView,
                       typeSelectActive: Bool = false) -> Bool {
        // A command whose UI has not landed yet (a pending Phase 2 command) leaves its key to the view rather than
        // beeping.
        guard let command = command(for: event, focus: focus, returnKey: returnKey, typeSelectActive: typeSelectActive),
              !FileCommandController.pendingCommands.contains(command) else { return false }
        return send(command, from: view)
    }

    /// Sends `command`'s action to the first responder up the chain from `view` that implements it, else nil-targeted.
    @discardableResult static func send(_ command: Command, from view: NSView) -> Bool {
        let action = Selector(command.selectorName)
        if let responder = responder(for: action, from: view) {
            return NSApp.sendAction(action, to: responder, from: view)
        }
        return NSApp.sendAction(action, to: nil, from: view)
    }

    /// The command a keyDown maps to with the active bindings (nil: not an alternate here).
    static func command(for event: NSEvent, focus: FocusContext, returnKey: ReturnKeyBehavior,
                        typeSelectActive: Bool = false) -> Command? {
        guard event.type == .keyDown, let chord = KeyEventTranslator.chord(for: event) else { return nil }
        return command(for: chord, focus: focus, returnKey: returnKey, typeSelectActive: typeSelectActive)
    }

    /// Pure: while type-select is collecting, plain Space is typed into its buffer (`my f` → "my file.txt"), not
    /// Quick Look (Review Focus 1).
    static func command(for chord: KeyChord, focus: FocusContext, returnKey: ReturnKeyBehavior,
                        typeSelectActive: Bool, bindings: KeyBindings = ActiveKeyBindings.current) -> Command? {
        if typeSelectActive, chord.key == .space, chord.modifiers.isEmpty { return nil }
        return KeyDispatcher(returnKey: returnKey, bindings: bindings).command(for: chord, in: focus)
    }

    private static func responder(for action: Selector, from view: NSView) -> NSResponder? {
        var next: NSResponder? = view
        while let current = next {
            if current.responds(to: action) { return current }
            if let target = current.supplementalTarget(forAction: action, sender: view) as? NSResponder { return target }
            next = current.nextResponder
        }
        return nil
    }
}

/// Tab / ⇧Tab order (§5.6): sidebar → address bar → content → sidebar. A field editor counts as content.
enum FocusCycle {
    static func next(after focus: FocusContext, forward: Bool) -> FocusContext {
        let order: [FocusContext] = [.sidebarFavorites, .addressBar, .content]
        let index = switch focus {
        case .sidebarFavorites, .sidebarLocations, .sidebarFolders, .sidebarVolumeRoot: 0
        case .addressBar: 1
        case .content, .fieldEditor: 2
        }
        return order[(index + (forward ? 1 : order.count - 1)) % order.count]
    }
}
