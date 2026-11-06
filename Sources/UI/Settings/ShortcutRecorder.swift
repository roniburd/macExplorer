import AppKit
import Core

/// Captures the next key press (or extra mouse button) for Settings › Shortcuts. A local event monitor runs before
/// sendEvent, so the captured event never reaches menus, key routing or MouseRouter.
@MainActor final class ShortcutRecorder {
    enum Outcome: Equatable {
        case trigger(Trigger)
        case clear
        case cancel
    }

    private var monitor: Any?
    private(set) var isRecording = false

    /// Esc cancels. ⌫ clears when `backspaceClears` (the Shortcut cell), else records ⌫. Mouse buttons only when
    /// `acceptsMouse` (the [+] extras). nil = not for the recorder; the event goes on as normal.
    static func outcome(for event: NSEvent, acceptsMouse: Bool, backspaceClears: Bool) -> Outcome? {
        switch event.type {
        case .keyDown:
            guard let chord = KeyEventTranslator.chord(for: event) else { return nil }
            if chord == KeyChord(.escape) { return .cancel }
            if backspaceClears, chord == KeyChord(.backspace) { return .clear }
            return .trigger(.key(chord))
        case .otherMouseDown:
            guard acceptsMouse, let button = MouseButton(number: event.buttonNumber) else { return nil }
            return .trigger(.mouse(button))
        default:
            return nil
        }
    }

    func start(acceptsMouse: Bool, backspaceClears: Bool, _ done: @escaping @MainActor (Outcome) -> Void) {
        stop()
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .otherMouseDown]) { [weak self] event in
            guard let outcome = Self.outcome(for: event, acceptsMouse: acceptsMouse, backspaceClears: backspaceClears) else {
                return event
            }
            self?.stop()
            done(outcome)
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }

    isolated deinit { stop() }
}
