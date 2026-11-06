import AppKit
import Core

/// Extra mouse buttons (Settings › Shortcuts; by default Mouse 4 = Back, Mouse 5 = Forward). Works anywhere in a
/// browser window, text fields included, as in browsers. The command goes to the window's content pane through the
/// same responder walk as alternate keys, so it acts as if the file list had focus; unavailable commands do nothing.
/// Like the keyboard path, it stands down while the window has a sheet or another window is running modally, so the
/// folder never changes behind a prompt about it; AppKit then handles (or discards) the event as usual.
@MainActor enum MouseRouter {
    /// Returns true if the event was a bound mouse button in a browser window (and was consumed).
    static func handle(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard event.type == .otherMouseDown,
              let button = MouseButton(number: event.buttonNumber),
              let command = ActiveKeyBindings.current.command(for: button),
              let controller = window?.windowController as? BrowserWindowController,
              let window = controller.window, window.attachedSheet == nil,
              NSApp.modalWindow == nil || NSApp.modalWindow === window,
              let view = controller.contentPane?.view else { return false }
        KeyRouter.send(command, from: view)
        return true
    }
}
