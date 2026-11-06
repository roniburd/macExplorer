import AppKit
import Core

/// Captures the next key press (or extra mouse button) for Settings › Shortcuts. A local event monitor runs before
/// sendEvent, so the captured event never reaches menus, key routing or MouseRouter.
/// Clicking elsewhere, a key or button aimed at another window, or the Settings window resigning key / closing
/// cancels (spec §5); those events are not swallowed.
@MainActor final class ShortcutRecorder {
    enum Outcome: Equatable {
        case trigger(Trigger)
        case clear
        case cancel
    }

    /// What the monitor does with an event while recording.
    enum Decision: Equatable {
        /// Recording ends with this outcome and the event is swallowed.
        case finish(Outcome)
        /// Recording is cancelled and the event goes on as normal (a click elsewhere, another window's event).
        case cancelAndPass
    }

    static let monitoredEvents: NSEvent.EventTypeMask = [.keyDown, .otherMouseDown, .leftMouseDown, .rightMouseDown]

    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var done: (@MainActor (Outcome) -> Void)?
    private var acceptsMouse = false
    private var backspaceClears = false
    private weak var window: NSWindow?
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

    /// Left/right clicks cancel anywhere; key and extra-button events aimed at another window cancel; otherwise
    /// `outcome(for:)` decides. nil = keep recording and let the event through.
    static func decision(for event: NSEvent, acceptsMouse: Bool, backspaceClears: Bool,
                         inRecordingWindow: Bool) -> Decision? {
        switch event.type {
        case .leftMouseDown, .rightMouseDown:
            return .cancelAndPass
        case .keyDown, .otherMouseDown:
            guard inRecordingWindow else { return .cancelAndPass }
            return outcome(for: event, acceptsMouse: acceptsMouse, backspaceClears: backspaceClears).map(Decision.finish)
        default:
            return nil
        }
    }

    /// Starts recording for `window` (the Settings window; nil = any window). `done` is called at most once;
    /// `stop()` ends recording without calling it.
    func start(in window: NSWindow?, acceptsMouse: Bool, backspaceClears: Bool,
               _ done: @escaping @MainActor (Outcome) -> Void) {
        stop()
        isRecording = true
        self.window = window
        self.acceptsMouse = acceptsMouse
        self.backspaceClears = backspaceClears
        self.done = done
        monitor = NSEvent.addLocalMonitorForEvents(matching: Self.monitoredEvents) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
        if let window {
            for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                    [weak self] _ in MainActor.assumeIsolated { self?.cancel() }
                })
            }
        }
    }

    /// The monitor body: returns the event to pass it on, nil to swallow it.
    func handle(_ event: NSEvent) -> NSEvent? {
        guard isRecording else { return event }
        let inWindow = window.map { event.windowNumber == $0.windowNumber } ?? true
        switch Self.decision(for: event, acceptsMouse: acceptsMouse, backspaceClears: backspaceClears,
                             inRecordingWindow: inWindow) {
        case nil:
            return event
        case .cancelAndPass:
            finish(.cancel)
            return event
        case .finish(let outcome):
            finish(outcome)
            return nil
        }
    }

    /// Ends recording with `.cancel`.
    func cancel() { finish(.cancel) }

    private func finish(_ outcome: Outcome) {
        guard isRecording, let done else { return }
        stop()
        done(outcome)
    }

    /// Ends recording without calling `done`.
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        done = nil
        window = nil
        isRecording = false
    }

    isolated deinit { stop() }
}
