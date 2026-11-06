import AppKit
import Core

/// The key table every window uses right now. `KeyBindingsController` replaces it whenever Settings › Shortcuts
/// changes; key routing, menu validation and mouse routing read it.
@MainActor enum ActiveKeyBindings {
    static var current: KeyBindings = .defaults
}

/// Keeps `ActiveKeyBindings.current` and the menu bar's key equivalents in step with `settings.keyBindingOverrides`.
@MainActor final class KeyBindingsController {
    private var loop: ObservationLoop?

    init(settings: Core.Settings, menu: @escaping @MainActor () -> NSMenu? = { NSApplication.shared.mainMenu }) {
        let apply: @MainActor () -> Void = { [weak settings] in
            guard let settings else { return }
            let bindings = settings.keyBindings
            ActiveKeyBindings.current = bindings
            if let menu = menu() { MainMenuBuilder.applyKeyEquivalents(bindings, to: menu) }
        }
        apply()
        loop = ObservationLoop({ [weak settings] in _ = settings?.keyBindingOverrides }, onChange: apply)
    }
}
