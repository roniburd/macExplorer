import AppKit
import Quartz
import Core

/// Quick Look on Space (P2-11, spec §11). The window controller is the shared panel's controller while its window is
/// key; each tab is its own window, so a tab switch hands the panel to the new tab's controller.
extension BrowserWindowController {
    /// Creates this window's QuickLookController over `panel` (tests pass an in-memory fake) and wires the bridge,
    /// the scenario hook and the current folder.
    func installQuickLook(panel: (@MainActor () -> any QuickLookPanelControlling)? = nil) {
        quickLook?.bind(nil)
        let bridge = qlBridge
        let system = SystemQuickLookPanel(bridge: bridge)
        let controller = QuickLookController(panel: panel ?? { system })
        quickLook = controller
        bridge.controller = controller
        bridge.forwardKeyEvent = { [weak self] event in
            // Arrows while the panel is key: the active list handles them; the first responder does not change.
            guard let list = (self?.contentPane as? ContentViewController)?.activeList as? FocusableList else { return }
            list.focusView.keyDown(with: event)
        }
        bridge.sourceFrame = { [weak self] url in
            guard let self, let row = self.quickLookRow(of: url),
                  let list = (self.contentPane as? ContentViewController)?.activeList as? QuickLookSourceList else { return nil }
            return list.quickLookSourceFrame(forModelRow: row)
        }
        scenarioHooks.quickLookState = { [weak controller] in
            (controller?.isVisible ?? false, controller?.items.map(\.lastPathComponent) ?? [])
        }
        controller.bind(session.results ?? session.folder)
    }

    /// The model row of a Quick Look item in what the window shows (folder or results).
    private func quickLookRow(of url: URL) -> Int? {
        if let results = session.results {
            return results.row(of: .name(url.path(percentEncoded: false))) ??
                (0..<results.rowCount).first { results.url(atRow: $0) == url }
        }
        return session.folder.row(named: url.lastPathComponent)
    }

    // QLPreviewPanelController is an informal NSObject protocol (nonisolated); the panel calls it on the main thread.
    public nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    public nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = qlBridge
            panel.delegate = qlBridge
        }
    }

    public nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            if panel.dataSource === qlBridge { panel.dataSource = nil }
            if panel.delegate === qlBridge { panel.delegate = nil }
        }
    }

    /// Tab switches and window changes: the panel asks the responder chain for its controller again.
    func quickLookWindowDidBecomeKey() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
        panel.updateController()
        if panel.dataSource === qlBridge { panel.reloadData() }
    }
}
