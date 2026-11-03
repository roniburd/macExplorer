import AppKit
import Core

/// Minimal NSAlert answers to file-operation questions, used until P1-38's InteractionRouter (§6.4, §6.5 in full)
/// replaces it. Shown as a sheet on the key browser window when there is one, otherwise app-modal.
@MainActor final class BasicAlertInteraction: FileOpInteraction {
    struct Prompt<Answer: Sendable & Equatable>: Sendable {
        struct Button: Sendable { var title: String; var answer: Answer }
        var message: String
        var informative: String
        var buttons: [Button]          // first = default; last = cancel

        /// The answer of the clicked button; an unexpected index is the last (cancel) button.
        func answer(forButtonIndex index: Int) -> Answer {
            buttons.indices.contains(index) ? buttons[index].answer : buttons[buttons.count - 1].answer
        }
    }

    init() {}

    // MARK: FileOpInteraction

    nonisolated func resolveConflict(_ conflict: ConflictInfo, job: JobSnapshot) async -> ConflictResolution {
        await present(Self.conflictPrompt(conflict))
    }

    nonisolated func resolveError(_ error: FileOpError, job: JobSnapshot) async -> ErrorResolution {
        await present(Self.errorPrompt(error))
    }

    nonisolated func confirmInsufficientSpace(_ shortfall: SpaceShortfall, job: JobSnapshot) async -> Bool {
        await present(Self.spacePrompt(shortfall))
    }

    nonisolated func confirmPermanentDeleteWithoutTrash(_ urls: [URL], job: JobSnapshot) async -> Bool {
        await present(Self.noTrashPrompt(urls))
    }

    // MARK: prompts (pure)

    nonisolated static func conflictPrompt(_ conflict: ConflictInfo) -> Prompt<ConflictResolution> {
        let name = conflict.pair.destination.url.lastPathComponent
        let first: Prompt<ConflictResolution>.Button = conflict.isFolderMerge
            ? .init(title: L10n.string("Merge"), answer: .one(.merge))
            : .init(title: L10n.string("Replace"), answer: .one(.replace))
        return Prompt(message: String(format: L10n.string("The destination already has an item named '%@'"), name),
                      informative: "",
                      buttons: [first,
                                .init(title: L10n.string("Keep Both"), answer: .one(.keepBoth)),
                                .init(title: L10n.string("Skip"), answer: .one(.skip)),
                                .init(title: L10n.string("Cancel"), answer: .cancelJob)])
    }

    nonisolated static func errorPrompt(_ error: FileOpError) -> Prompt<ErrorResolution> {
        let message = String(format: L10n.string("The operation couldn't be completed for '%@'"), error.url.lastPathComponent)
        let buttons = error.kind.allowedResolutions.map { Prompt<ErrorResolution>.Button(title: title(for: $0), answer: $0) }
        return Prompt(message: message, informative: "", buttons: buttons)
    }

    nonisolated static func spacePrompt(_ shortfall: SpaceShortfall) -> Prompt<Bool> {
        Prompt(message: String(format: L10n.string("There isn't enough space on '%@'"), shortfall.volumeName),
               informative: "",
               buttons: [.init(title: L10n.string("Continue Anyway"), answer: true), .init(title: L10n.string("Cancel"), answer: false)])
    }

    nonisolated static func noTrashPrompt(_ urls: [URL]) -> Prompt<Bool> {
        let message = urls.count == 1
            ? String(format: L10n.string("'%@' can't be moved to the Trash. Delete it permanently?"), urls[0].lastPathComponent)
            : String(format: L10n.string("%ld items can't be moved to the Trash. Delete them permanently?"), urls.count)
        return Prompt(message: message, informative: L10n.string("You can't undo this action."),
                      buttons: [.init(title: L10n.string("Delete"), answer: true), .init(title: L10n.string("Cancel"), answer: false)])
    }

    nonisolated static func title(for resolution: ErrorResolution) -> String {
        switch resolution {
        case .retry: L10n.string("Try Again")
        case .skip: L10n.string("Skip")
        case .skipAll: L10n.string("Skip All")
        case .cancel: L10n.string("Cancel")
        case .unlockAndContinue: L10n.string("Unlock and Continue")
        case .continueAnyway: L10n.string("Continue Anyway")
        }
    }

    // MARK: presentation

    private func present<Answer>(_ prompt: Prompt<Answer>) async -> Answer {
        let alert = NSAlert()
        alert.messageText = prompt.message
        alert.informativeText = prompt.informative
        for button in prompt.buttons { alert.addButton(withTitle: button.title) }
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow ?? NSApp.mainWindow, window.windowController is BrowserWindowController,
           window.attachedSheet == nil {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        return prompt.answer(forButtonIndex: response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue)
    }
}
