import AppKit
import Core

/// One question a job asks through FileOpInteraction, in a form presenters and tests can compare.
enum InteractionQuestion: Sendable, Equatable {
    case conflict(ConflictInfo)
    case error(FileOpError)
    case space(SpaceShortfall)
    case noTrash([URL])

    /// The answer when a dialog goes away without one (Task cancelled, sheet ended from outside): stop safely.
    var fallback: InteractionAnswer {
        switch self {
        case .conflict: .conflict(.cancelJob)
        case .error: .error(.cancel)
        case .space, .noTrash: .confirm(false)
        }
    }
}

enum InteractionAnswer: Sendable, Equatable {
    case conflict(ConflictResolution)
    case error(ErrorResolution)
    case confirm(Bool)
}

/// Where a question appears (§6.2): a sheet on the window that started the job, or the Operations panel.
enum DialogHost: Hashable, Sendable {
    case window(OriginID)
    case operationsPanel
}

@MainActor
protocol DialogPresenting: AnyObject {
    /// Shows `question` as a sheet on `window` (a standalone panel when nil) and returns the answer, or nil when the
    /// dialog went away without one: its window closed, the calling Task was cancelled, or the sheet was ended outside.
    func present(_ question: InteractionQuestion, job: JobSnapshot, on window: NSWindow?) async -> InteractionAnswer?
}

/// FIFO async mutex on the main actor: one dialog per host at a time, in arrival order (slice Review Focus 5).
@MainActor
final class SerialGate {
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var waitingCount: Int { waiters.count }

    func enter() async {
        guard isBusy else {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hands the gate to the oldest waiter, or frees it.
    func leave() {
        if waiters.isEmpty { isBusy = false } else { waiters.removeFirst().resume() }
    }
}

/// Answers every FileOpInteraction question with a dialog (§6.2, §6.4, §6.5): a sheet on the window that started the
/// job, or the Operations panel when that window has closed (also while the question was waiting or showing).
/// Questions for one host are shown one at a time; errors from Properties windows are answered Skip and shown there.
@MainActor
final class InteractionRouter: FileOpInteraction {
    private let windows: WindowManager
    var presenter: any DialogPresenting
    /// The Operations panel's window, shown on demand (OperationsUI sets it).
    var panelWindow: (@MainActor () -> NSWindow?)?
    /// Origins whose job errors are answered .skip without a dialog; the window shows them inline (§5.8).
    var answersInline: @MainActor (OriginID) -> Bool = { PropertiesWindowController.answersErrorsInline($0) }
    private let resolveHost: (@MainActor (OriginID?) -> DialogHost)?
    private var gates: [DialogHost: SerialGate] = [:]
    /// Where each waiting job's question is showing (Operations list "Show", tests).
    private(set) var pendingHosts: [JobID: DialogHost] = [:]
    /// The presenting Task of each open dialog, so Stop and Quit can end them.
    private var openDialogs: [JobID: Task<InteractionAnswer?, Never>] = [:]
    /// Set by stopAnswering(): every question from then on gets its fallback without a dialog.
    private(set) var isStopping = false

    /// §3.14. Presents with a URL opener that only records; OperationsUI swaps in the real presenter.
    convenience init(windows: WindowManager) {
        self.init(windows: windows, presenter: AppKitDialogPresenter(icons: nil, opener: RecordingURLOpener.shared))
    }

    /// Tests inject a presenter and, optionally, fake host rules.
    init(windows: WindowManager, presenter: any DialogPresenting, resolveHost: (@MainActor (OriginID?) -> DialogHost)? = nil) {
        self.windows = windows
        self.presenter = presenter
        self.resolveHost = resolveHost
    }

    // MARK: FileOpInteraction (called from the FileOpQueue actor; hop to main)

    nonisolated func resolveConflict(_ conflict: ConflictInfo, job: JobSnapshot) async -> ConflictResolution {
        if case .conflict(let resolution) = await ask(.conflict(conflict), job: job) { return resolution }
        return .cancelJob
    }

    nonisolated func resolveError(_ error: FileOpError, job: JobSnapshot) async -> ErrorResolution {
        if case .error(let resolution) = await ask(.error(error), job: job) { return resolution }
        return .cancel
    }

    nonisolated func confirmInsufficientSpace(_ shortfall: SpaceShortfall, job: JobSnapshot) async -> Bool {
        if case .confirm(let ok) = await ask(.space(shortfall), job: job) { return ok }
        return false
    }

    nonisolated func confirmPermanentDeleteWithoutTrash(_ urls: [URL], job: JobSnapshot) async -> Bool {
        if case .confirm(let ok) = await ask(.noTrash(urls), job: job) { return ok }
        return false
    }

    // MARK: hosts

    /// The window that shows sheets for `origin`: an open browser window (tab), or an open Properties window. nil
    /// means the Operations panel. A browser tab that is not the selected one in its tab group is selected first, so
    /// the sheet never appears behind another tab (P2-05, Review Focus 4).
    func hostWindow(for origin: OriginID?) -> NSWindow? {
        guard let window = candidateWindow(for: origin) else { return nil }
        if let group = window.tabGroup, group.selectedWindow !== window { group.selectedWindow = window }
        return window
    }

    func route(_ origin: OriginID?) -> DialogHost {
        if let resolveHost { return resolveHost(origin) }
        guard let origin, candidateWindow(for: origin) != nil else { return .operationsPanel }
        return .window(origin)
    }

    /// hostWindow(for:) without selecting a tab: routing and re-checks must not switch tabs on their own.
    private func candidateWindow(for origin: OriginID?) -> NSWindow? {
        guard let origin else { return nil }
        if let window = windows.window(for: origin)?.window, Self.canHostSheet(window) { return window }
        if let window = NSApp.window(withWindowNumber: origin.raw), window.identifier?.rawValue == AXID.propertiesWindow,
           Self.canHostSheet(window) {
            return window
        }
        return nil
    }

    func window(for host: DialogHost) -> NSWindow? {
        switch host {
        case .window(let origin): hostWindow(for: origin)
        case .operationsPanel: panelWindow?()
        }
    }

    /// Operations list "Show": bring the window holding this job's question to the front.
    func revealQuestion(for job: JobID) {
        guard let host = pendingHosts[job], let window = window(for: host) else { return }
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Stop and Quit

    /// Called by the Stop and Quit flow (P1-30's AppLifecycle) right before `termination.stopAllAndWait()` (§6.7,
    /// S3 Contract note 18): closes every open dialog unanswered and answers every waiting or later question with
    /// its fallback (.cancelJob / .cancel / false), so the cancelled jobs finish their cancel path (partials removed,
    /// journal updated) before the 10 s timeout. Not reversible: the app is quitting.
    func stopAnswering() {
        isStopping = true
        for task in openDialogs.values { task.cancel() }
    }

    // MARK: asking

    func ask(_ question: InteractionQuestion, job: JobSnapshot) async -> InteractionAnswer {
        if isStopping { return question.fallback }
        if case .error = question, let origin = job.origin, answersInline(origin) { return .error(.skip) }
        var host = route(job.origin)
        while true {
            let gate = gate(for: host)
            await gate.enter()
            if Task.isCancelled || isStopping {
                gate.leave()
                return question.fallback
            }
            if case .window(let origin) = host, route(origin) != host {   // closed while this question waited
                gate.leave()
                host = .operationsPanel
                continue
            }
            pendingHosts[job.id] = host
            let hostWindow = window(for: host)
            // A child Task, so stopAnswering() can cancel it; the presenter treats cancellation as "went away".
            let presenting = Task { @MainActor [self] in await self.presenter.present(question, job: job, on: hostWindow) }
            openDialogs[job.id] = presenting
            let answer = await withTaskCancellationHandler {
                await presenting.value
            } onCancel: {
                presenting.cancel()
            }
            openDialogs[job.id] = nil
            pendingHosts[job.id] = nil
            gate.leave()
            if isStopping { return question.fallback }
            if let answer { return answer }
            if Task.isCancelled { return question.fallback }
            if case .window(let origin) = host, route(origin) != host {   // the window closed under its sheet
                host = .operationsPanel
                continue
            }
            return question.fallback
        }
    }

    private func gate(for host: DialogHost) -> SerialGate {
        if let gate = gates[host] { return gate }
        let gate = SerialGate()
        gates[host] = gate
        return gate
    }

    /// Visible or minimized; a background tab counts when its tab group's selected tab does (it is ordered out only
    /// because another tab is selected).
    private static func canHostSheet(_ window: NSWindow) -> Bool {
        if window.isVisible || window.isMiniaturized { return true }
        guard let group = window.tabGroup, group.windows.contains(where: { $0 === window }),
              let selected = group.selectedWindow, selected !== window else { return false }
        return selected.isVisible || selected.isMiniaturized
    }
}
