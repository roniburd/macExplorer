import AppKit
import Core

/// The §6.7 quit question's answers.
enum QuitChoice: Sendable, Equatable { case stopAndQuit, cancel }

/// Asks "N operations are in progress" (tests answer from a script).
@MainActor protocol QuitPrompting: AnyObject {
    func confirmQuit(activeCount: Int) async -> QuitChoice
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

/// App-modal NSAlert (the question is about the whole app, not one window).
@MainActor final class AlertQuitPrompts: QuitPrompting {
    func confirmQuit(activeCount: Int) async -> QuitChoice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = QuitPromptText.message(activeCount: activeCount)
        alert.informativeText = QuitPromptText.informative
        alert.addButton(withTitle: QuitPromptText.stopAndQuit)
        alert.addButton(withTitle: QuitPromptText.cancel)
        return alert.runModal() == .alertFirstButtonReturn ? .stopAndQuit : .cancel
    }
}
