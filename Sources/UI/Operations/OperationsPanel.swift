import AppKit
import SwiftUI
import Core

/// Window › Operations (§6.7): a standalone panel with the popover's job list. It stays up while the app is
/// inactive or has no browser windows, and hosts the dialogs of jobs whose window has closed (§6.2).
@MainActor
final class OperationsPanelController: NSWindowController, NSWindowDelegate {
    private let context: UIContext

    init(context: UIContext, content: OperationsListView) {
        self.context = context
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        panel.title = L10n.string("Operations")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.identifier = NSUserInterfaceItemIdentifier(AXID.operationsPanel)
        panel.setAccessibilityIdentifier(AXID.operationsPanel)
        super.init(window: panel)
        panel.delegate = self
        panel.contentViewController = NSHostingController(rootView: content)
        panel.center()
    }

    required init?(coder: NSCoder) { fatalError("OperationsPanelController is created in code") }

    func showPanel() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Dialog host for questions whose window has closed: shows the panel and returns it.
    func windowForDialogs() -> NSWindow? {
        showPanel()
        return window
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        context.environment.undo.undoManager
    }
}

/// App-wide progress and dialog UI, owned by UIContext: the interaction router, the Operations panel, the job
/// list it shows, and the state of every window's progress card.
@MainActor
final class OperationsUI {
    private unowned let context: UIContext
    let router: InteractionRouter
    let card = ProgressCardState()
    private var panelController: OperationsPanelController?

    init(context: UIContext) {
        self.context = context
        router = InteractionRouter(windows: context.windows,
                                   presenter: AppKitDialogPresenter(icons: context.icons, opener: ExternalOpeners.opener(for: context.options)))
        router.panelWindow = { [unowned self] in self.panel.windowForDialogs() }
    }

    /// Created on first use (Window › Operations, or the first question without a window).
    var panel: OperationsPanelController {
        if let panelController { return panelController }
        let created = OperationsPanelController(context: context, content: listView())
        panelController = created
        return created
    }

    func showPanel() { panel.showPanel() }

    /// Closes the panel if it was ever created (test teardown).
    func closePanel() { panelController?.close() }

    func listView() -> OperationsListView {
        OperationsListView(operations: context.environment.operations, actions: jobActions())
    }

    func cardView(onCardFrame: @escaping (CGRect) -> Void) -> ProgressCardView {
        ProgressCardView(operations: context.environment.operations, state: card, actions: jobActions(),
                         onCardFrame: onCardFrame)
    }

    private func jobActions() -> JobActions {
        let queue = context.environment.fileOps
        let router = router
        return JobActions(
            pause: { id in Task { await queue.pause(id) } },
            resume: { id in Task { await queue.resume(id) } },
            cancel: { [operations = context.environment.operations] id in
                // External activities (remote downloads) cancel through their own handler, not the queue.
                if !operations.cancelExternal(id) { Task { await queue.cancel(id) } }
            },
            showQuestion: { [weak router] id in router?.revealQuestion(for: id) })
    }
}
