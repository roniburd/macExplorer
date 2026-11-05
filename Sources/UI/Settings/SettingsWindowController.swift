import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Core

/// Hosts SettingsView (§7) in one non-restorable window per app (macExplorer › Settings…, ⌘,). Closing it drops the
/// controller; the next Settings… builds a fresh one.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private weak var context: UIContext?

    /// Shows (and focuses) the app's Settings window, creating it on first use.
    @discardableResult
    static func show(context: UIContext) -> SettingsWindowController {
        let controller = context.settingsWindow ?? SettingsWindowController(context: context)
        context.settingsWindow = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    private init(context: UIContext) {
        self.context = context
        let view = SettingsView(settings: context.environment.settings, panels: OpenPanelSettingsPanels(),
                                updates: context.updates)
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable]
        window.title = L10n.string("MacExplorer Settings")
        window.setAccessibilityIdentifier(AXID.settingsWindow)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("SettingsWindowController is created in code") }

    func windowWillClose(_ notification: Notification) {
        if context?.settingsWindow === self { context?.settingsWindow = nil }
    }
}

/// Folder and application choosers for the General section (modal NSOpenPanel; only a user click runs them).
@MainActor
final class OpenPanelSettingsPanels: SettingsPanels {
    func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.string("Choose")
        return panel.runModal() == .OK ? panel.url : nil
    }

    func chooseApplication() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(filePath: "/Applications", directoryHint: .isDirectory)
        panel.prompt = L10n.string("Choose")
        return panel.runModal() == .OK ? panel.url : nil
    }
}
