import AppKit
import SwiftUI
import Core
import MacxFS

/// §6.4 conflict dialog content, decided from ConflictInfo alone.
struct ConflictDialogModel: Equatable {
    enum Choice: Hashable {
        case action(ConflictAction)
        case compare
        case cancel
    }

    let title: String
    let message: String
    let choices: [Choice]
    let applyToAllTitle: String?          // only when more than one conflict is known
    let defaultAction: ConflictAction     // Return: never Replace

    @MainActor
    init(_ info: ConflictInfo) {
        let name = info.pair.destination.url.lastPathComponent
        if info.isFolderMerge {
            title = L10n.string("Merge folders?")
            message = String(format: L10n.string("The destination already has a folder named '%@'. Merging adds the items of both folders to it."), name)
            choices = [.action(.merge), .action(.keepBoth), .action(.skip), .cancel]
            defaultAction = .merge
        } else {
            title = info.pair.destination.isDirectory
                ? String(format: L10n.string("The destination already has a folder named '%@'"), name)
                : String(format: L10n.string("The destination already has a file named '%@'"), name)
            message = L10n.string("Replace it with the item you're copying or moving, skip this item, or keep both.")
            choices = [.action(.replace), .action(.skip), .action(.keepBoth), .compare, .cancel]
            defaultAction = .keepBoth
        }
        applyToAllTitle = info.knownRemaining > 1
            ? String(format: L10n.string("Do this for all remaining conflicts (%lld)"), info.knownRemaining) : nil
    }

    func resolution(_ action: ConflictAction, applyToAll: Bool) -> ConflictResolution {
        applyToAll && applyToAllTitle != nil ? .all(action) : .one(action)
    }

    @MainActor
    static func title(_ choice: Choice) -> String {
        switch choice {
        case .action(.replace): L10n.string("Replace")
        case .action(.skip): L10n.string("Skip")
        case .action(.keepBoth): L10n.string("Keep Both")
        case .action(.merge): L10n.string("Merge")
        case .compare: L10n.string("Compare…")
        case .cancel: L10n.string("Cancel")
        }
    }
}

struct ConflictDialogView: View {
    let model: ConflictDialogModel
    let jobTitle: String
    let icon: @MainActor (ItemSummary) -> NSImage?
    let answer: @MainActor (ConflictResolution) -> Void
    @State private var compare: CompareSelection
    @State private var applyToAll = false
    @State private var isComparing = false

    init(model: ConflictDialogModel, jobTitle: String, compare: CompareSelection,
         icon: @escaping @MainActor (ItemSummary) -> NSImage?, answer: @escaping @MainActor (ConflictResolution) -> Void) {
        self.model = model
        self.jobTitle = jobTitle
        self.icon = icon
        self.answer = answer
        _compare = State(initialValue: compare)
    }

    var body: some View {
        if isComparing {
            CompareView(selection: $compare, icon: icon, onContinue: { answer(compare.resolution) }, onBack: { isComparing = false })
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: jobTitle).font(.caption).foregroundStyle(.secondary)
                Text(verbatim: model.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                Text(verbatim: model.message).fixedSize(horizontal: false, vertical: true)
                if let toAll = model.applyToAllTitle {
                    Toggle(toAll, isOn: $applyToAll).accessibilityIdentifier("macx.conflict.applyToAll")
                }
                HStack {
                    Spacer()
                    ForEach(model.choices, id: \.self) { choice in button(for: choice) }
                }
            }
            .padding(20)
            .frame(width: 520, alignment: .leading)
        }
    }

    @ViewBuilder
    private func button(for choice: ConflictDialogModel.Choice) -> some View {
        let title = ConflictDialogModel.title(choice)
        switch choice {
        case .action(let action):
            Button(title) { answer(model.resolution(action, applyToAll: applyToAll)) }
                .keyboardShortcut(action == model.defaultAction ? .defaultAction : nil)
                .accessibilityIdentifier(AXID.conflictButton(action))
        case .compare:
            Button(title) { isComparing = true }.accessibilityIdentifier("macx.conflict.compare")
        case .cancel:
            Button(title, role: .cancel) { answer(.cancelJob) }.keyboardShortcut(.cancelAction)
        }
    }
}

/// Runs one dialog as a sheet on a window (a centred panel when there is none) and resumes exactly once: with the
/// button's answer, or nil when the sheet is ended from outside, its window closes, or the Task is cancelled.
@MainActor
final class SheetHost {
    let panel: NSPanel
    private var continuation: CheckedContinuation<InteractionAnswer?, Never>?
    private var answer: InteractionAnswer?
    private var isDone = false
    private weak var parent: NSWindow?
    private var closeObserver: (any NSObjectProtocol)?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
    }

    func run(_ content: AnyView, on window: NSWindow?) async -> InteractionAnswer? {
        guard !isDone else { return answer }
        let hosting = NSHostingController(rootView: content)
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentViewController = hosting
        panel.setContentSize(hosting.view.fittingSize)
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            if let window {
                parent = window
                closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                                       queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.finish(nil) }
                }
                window.beginSheet(panel) { [weak self] _ in
                    MainActor.assumeIsolated { self?.resume() }
                }
            } else {
                panel.center()
                panel.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// A button's answer, or nil to dismiss. Idempotent: only the first call counts.
    func finish(_ value: InteractionAnswer?) {
        guard !isDone else { return }
        isDone = true
        answer = value
        if let parent, panel.sheetParent === parent {
            parent.endSheet(panel)              // the completion handler resumes
        } else {
            panel.orderOut(nil)
            resume()
        }
    }

    private func resume() {
        isDone = true
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        continuation?.resume(returning: answer)
        continuation = nil
    }
}

/// The real presenter: SwiftUI dialogs in sheets. Side effects go through ExternalURLOpening (S5-C2).
@MainActor
final class AppKitDialogPresenter: DialogPresenting {
    private let icons: IconCache?
    private let opener: any ExternalURLOpening
    private let types: TypeRegistry

    init(icons: IconCache?, opener: any ExternalURLOpening, types: TypeRegistry = .shared) {
        self.icons = icons
        self.opener = opener
        self.types = types
    }

    func present(_ question: InteractionQuestion, job: JobSnapshot, on window: NSWindow?) async -> InteractionAnswer? {
        let sheet = SheetHost()
        let view = content(for: question, job: job) { [weak sheet] answer in sheet?.finish(answer) }
        return await withTaskCancellationHandler {
            await sheet.run(view, on: window)
        } onCancel: {
            Task { @MainActor in sheet.finish(nil) }
        }
    }

    func content(for question: InteractionQuestion, job: JobSnapshot,
                 answer: @escaping @MainActor (InteractionAnswer) -> Void) -> AnyView {
        let press: @MainActor (DialogButton) -> Void = { [weak self] button in
            guard let self else { return }
            answer(self.handle(button))
        }
        switch question {
        case .conflict(let info):
            return AnyView(ConflictDialogView(model: ConflictDialogModel(info), jobTitle: JobTitle.title(job.description),
                                              compare: CompareSelection(info), icon: { [weak self] in self?.icon(for: $0) },
                                              answer: { answer(.conflict($0)) }))
        case .error(let error):
            return AnyView(ErrorDialogView(model: .error(error, job: job), press: press))
        case .space(let shortfall):
            return AnyView(ErrorDialogView(model: .space(shortfall, job: job), press: press))
        case .noTrash(let urls):
            return AnyView(ErrorDialogView(model: .noTrash(urls, job: job), press: press))
        }
    }

    /// Runs a button's side effect, then returns its answer (§3.13: Open Privacy Settings opens the pane and retries).
    func handle(_ button: DialogButton) -> InteractionAnswer {
        if button.sideEffect == .openPrivacySettings { opener.open(SystemSettingsLinks.privacyAllFiles) }
        return button.answer
    }

    /// Tier 0 type icon (no file-system call, S5-C3).
    func icon(for item: ItemSummary) -> NSImage? {
        guard let icons else { return nil }
        let index = types.index(forExtension: Substring(item.url.pathExtension), isDirectory: item.isDirectory)
        return NSImage(cgImage: icons.typeIcon(index, points: 32, scale: 2), size: NSSize(width: 32, height: 32))
    }
}
