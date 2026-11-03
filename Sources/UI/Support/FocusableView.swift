import AppKit
import Core
import MacxFS

/// A plain view that takes keyboard focus, so a pane without its own list sits in the responder chain. `onKeyDown` sees
/// each key first (KeyRouter alternates); unhandled keys go to super.
@MainActor
final class FocusableView: NSView {
    var onKeyDown: ((NSEvent) -> Bool)?
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }
}
