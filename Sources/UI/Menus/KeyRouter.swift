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
    static func handle(_ event: NSEvent, focus: FocusContext, returnKey: ReturnKeyBehavior, from view: NSView) -> Bool {
        guard let command = command(for: event, focus: focus, returnKey: returnKey) else { return false }
        let action = Selector(command.selectorName)
        if let responder = responder(for: action, from: view) {
            return NSApp.sendAction(action, to: responder, from: view)
        }
        return NSApp.sendAction(action, to: nil, from: view)
    }

    /// The command a keyDown maps to (nil: not an alternate here).
    static func command(for event: NSEvent, focus: FocusContext, returnKey: ReturnKeyBehavior) -> Command? {
        guard event.type == .keyDown, let chord = KeyEventTranslator.chord(for: event) else { return nil }
        return KeyDispatcher(returnKey: returnKey).command(for: chord, in: focus)
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
