import AppKit
import Core

/// The §6.7 quit question's answers. `.jobsFinished`: every job ended while it was asked (the prompt was dismissed).
enum QuitChoice: Sendable, Equatable { case stopAndQuit, cancel, jobsFinished }

/// Asks "N operations are in progress" (tests answer from a script). `dismiss()` closes an open question, which then
/// answers `.jobsFinished`; it is a no-op when nothing is asked.
@MainActor protocol QuitPrompting: AnyObject {
    func confirmQuit(activeCount: Int) async -> QuitChoice
    func dismiss()
}

/// What Stop and Quit needs from the job engine (TerminationCoordinator; tests pass a fake).
@MainActor protocol JobTerminating: AnyObject {
    var activeCount: Int { get }
    func stopAllAndWait(timeout: Duration) async -> Bool
}

extension TerminationCoordinator: JobTerminating {}

@MainActor enum QuitPromptText {
    static func message(activeCount: Int) -> String {
        activeCount == 1 ? L10n.string("1 operation is in progress")
                         : String(format: L10n.string("%ld operations are in progress"), activeCount)
    }
    static var informative: String {
        L10n.string("Stop and Quit cancels them safely: each finishes its current item and removes incomplete copies.")
    }
    static var stopAndQuit: String { L10n.string("Stop and Quit") }
    static var cancel: String { L10n.string("Cancel") }
}

/// The quit NSAlert, shown as a floating panel rather than with `runModal()`: a synchronous modal inside a main-actor
/// task stalls every other main-actor job (progress, job completions), so the prompt went stale and the app never
/// noticed the last job finishing (QA round 2). The buttons answer through a continuation instead.
@MainActor final class AlertQuitPrompts: NSObject, QuitPrompting {
    private var alert: NSAlert?
    private var continuation: CheckedContinuation<QuitChoice, Never>?

    func confirmQuit(activeCount: Int) async -> QuitChoice {
        finish(.cancel)                                   // never two questions at once
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = QuitPromptText.message(activeCount: activeCount)
        alert.informativeText = QuitPromptText.informative
        for (tag, title) in [QuitPromptText.stopAndQuit, QuitPromptText.cancel].enumerated() {
            let button = alert.addButton(withTitle: title)
            button.tag = tag
            button.target = self
            button.action = #selector(answer(_:))
        }
        alert.layout()
        let window = alert.window
        window.level = .modalPanel
        window.center()
        self.alert = alert
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
    }

    func dismiss() { finish(.jobsFinished) }

    @objc private func answer(_ sender: NSButton) {
        finish(sender.tag == 0 ? .stopAndQuit : .cancel)
    }

    private func finish(_ choice: QuitChoice) {
        alert?.window.orderOut(nil)
        alert = nil
        let pending = continuation
        continuation = nil
        pending?.resume(returning: choice)
    }
}
