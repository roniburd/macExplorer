import AppKit

enum CrashChoice: Equatable { case report, showReport, dontSend }
struct CrashAnswer: Equatable { var choice: CrashChoice; var dontAskAgain: Bool }

@MainActor protocol CrashPrompting: AnyObject {
    func ask(title: String, on window: NSWindow?) async -> CrashAnswer
}

/// The next-launch sheet (spec §4.2). Waits until the window has no other sheet (onboarding, recovery notice).
@MainActor final class AlertCrashPrompt: CrashPrompting {
    func ask(title: String, on window: NSWindow?) async -> CrashAnswer {
        while let window, window.attachedSheet != nil { try? await Task.sleep(for: .milliseconds(250)) }
        let alert = Self.makeAlert(title: title)
        let response: NSApplication.ModalResponse
        if let window, window.isVisible {
            response = await withCheckedContinuation { c in alert.beginSheetModal(for: window) { c.resume(returning: $0) } }
        } else {
            response = alert.runModal()
        }
        let choice: CrashChoice = switch response {
        case .alertFirstButtonReturn: .report
        case .alertSecondButtonReturn: .showReport
        default: .dontSend
        }
        return CrashAnswer(choice: choice, dontAskAgain: alert.suppressionButton?.state == .on)
    }

    static func makeAlert(title: String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.string("MacExplorer quit unexpectedly last time")
        alert.informativeText = L10n.string("Help fix it by reporting the crash. You'll see the report on GitHub before anything is sent.")
            + "\n\n" + title
        alert.addButton(withTitle: L10n.string("Report on GitHub…"))
        alert.addButton(withTitle: L10n.string("Show Report"))
        // NSAlert gives Escape only to a button titled "Cancel"; Don't Send is the dismiss button.
        alert.addButton(withTitle: L10n.string("Don't Send")).keyEquivalent = "\u{1b}"
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = L10n.string("Don't ask again")
        return alert
    }
}
