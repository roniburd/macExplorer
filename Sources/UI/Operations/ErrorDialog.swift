import SwiftUI
import Core
import MacxFS

struct DialogButton: Equatable, Identifiable {
    enum Role: Equatable { case normal, destructive, cancel }
    enum SideEffect: Equatable { case openPrivacySettings }

    let title: String
    let answer: InteractionAnswer
    var role: Role = .normal
    var isDefault = false
    var sideEffect: SideEffect?

    var id: String { title }
}

/// §6.5 dialogs: the table's message as the title and exactly its actions, in order; plus the free-space and
/// "no Trash" prompts. `context` is the job's title.
struct ErrorDialogModel: Equatable {
    let context: String
    let title: String
    let detail: String?
    let buttons: [DialogButton]

    @MainActor
    static func error(_ error: FileOpError, job: JobSnapshot, locale: Locale = .current) -> ErrorDialogModel {
        ErrorDialogModel(context: JobTitle.title(job.description, locale: locale),
                         title: ErrorText.jobError(error.kind, name: error.url.lastPathComponent, verb: job.description.verb),
                         detail: detail(error.kind),
                         buttons: error.kind.allowedResolutions.map { button(for: $0, kind: error.kind) })
    }

    @MainActor
    static func space(_ shortfall: SpaceShortfall, job: JobSnapshot, locale: Locale = .current) -> ErrorDialogModel {
        ErrorDialogModel(context: JobTitle.title(job.description, locale: locale),
                         title: String(format: L10n.string("Not enough space on '%@'"), shortfall.volumeName),
                         detail: String(format: L10n.string("This operation needs %@, but only %@ is available."),
                                        Formatters.bytes(shortfall.needed), Formatters.bytes(shortfall.available)),
                         buttons: [DialogButton(title: L10n.string("Continue Anyway"), answer: .confirm(true)),
                                   DialogButton(title: L10n.string("Cancel"), answer: .confirm(false), role: .cancel, isDefault: true)])
    }

    /// §6.3: volumes without a Trash fall back to "Delete permanently?" with confirmation.
    @MainActor
    static func noTrash(_ urls: [URL], job: JobSnapshot, locale: Locale = .current) -> ErrorDialogModel {
        let single = urls.count == 1
        return ErrorDialogModel(
            context: JobTitle.title(job.description, locale: locale),
            title: single ? String(format: L10n.string("'%@' can't be moved to the Trash."), urls[0].lastPathComponent)
                          : String(format: L10n.string("%lld items can't be moved to the Trash."), urls.count),
            detail: single ? L10n.string("Do you want to delete it permanently? This can't be undone.")
                           : L10n.string("Do you want to delete them permanently? This can't be undone."),
            buttons: [DialogButton(title: L10n.string("Delete"), answer: .confirm(true), role: .destructive),
                      DialogButton(title: L10n.string("Cancel"), answer: .confirm(false), role: .cancel, isDefault: true)])
    }

    @MainActor
    static func button(for resolution: ErrorResolution, kind: FileOpErrorKind) -> DialogButton {
        switch resolution {
        case .retry where kind == .blockedByMacOS:
            DialogButton(title: L10n.string("Open Privacy Settings"), answer: .error(.retry), isDefault: true, sideEffect: .openPrivacySettings)
        case .retry: DialogButton(title: L10n.string("Retry"), answer: .error(.retry), isDefault: true)
        case .skip: DialogButton(title: L10n.string("Skip"), answer: .error(.skip))
        case .skipAll: DialogButton(title: L10n.string("Skip All"), answer: .error(.skipAll))
        case .cancel: DialogButton(title: L10n.string("Cancel"), answer: .error(.cancel), role: .cancel)
        case .unlockAndContinue: DialogButton(title: L10n.string("Unlock and Continue"), answer: .error(.unlockAndContinue), isDefault: true)
        case .continueAnyway: DialogButton(title: L10n.string("Continue Anyway"), answer: .error(.continueAnyway))
        }
    }

    @MainActor
    private static func detail(_ kind: FileOpErrorKind) -> String? {
        switch kind {
        case .blockedByMacOS: L10n.string("Allow macExplorer in System Settings › Privacy & Security, then try again.")
        case .locked: L10n.string("Unlocking removes the Locked attribute so the operation can continue.")
        case .noSpace: L10n.string("Free up space on the destination, then try again.")
        default: nil
        }
    }
}

struct ErrorDialogView: View {
    let model: ErrorDialogModel
    let press: @MainActor (DialogButton) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30)).foregroundStyle(.yellow).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: model.context).font(.caption).foregroundStyle(.secondary)
                Text(verbatim: model.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                if let detail = model.detail { Text(verbatim: detail).fixedSize(horizontal: false, vertical: true) }
                HStack {
                    Spacer()
                    ForEach(model.buttons) { button in
                        Button(button.title, role: role(button)) { press(button) }
                            .keyboardShortcut(shortcut(button))
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 460, alignment: .leading)
    }

    private func role(_ button: DialogButton) -> ButtonRole? {
        switch button.role {
        case .normal: nil
        case .destructive: .destructive
        case .cancel: .cancel
        }
    }

    private func shortcut(_ button: DialogButton) -> KeyboardShortcut? {
        if button.isDefault { return .defaultAction }
        return button.role == .cancel ? .cancelAction : nil
    }
}
