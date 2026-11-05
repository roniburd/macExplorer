import AppKit
import UniformTypeIdentifiers
import Core

enum CommandPrompt: Equatable, Sendable {
    case openManyWindows(Int)
    case openManyTabs(Int)
    case applyViewToAllFolders
    case confirmTrash(Int)
    case confirmDelete(Int)
    case brokenLink(String)
    case openFailed(file: String, app: String?, message: String)
    case ejectFailed(volume: String, processes: [String], message: String?)
}

enum BrokenLinkChoice: Sendable { case delete, fix, cancel }

/// Alerts and panels used by FileCommandController. A seam: tests install a scripted implementation.
@MainActor protocol CommandPrompts: AnyObject {
    func confirm(_ prompt: CommandPrompt, window: NSWindow?) async -> Bool
    func inform(_ prompt: CommandPrompt, window: NSWindow?) async
    func brokenLink(_ name: String, window: NSWindow?) async -> BrokenLinkChoice
    func chooseFile(directory: URL?, applicationsOnly: Bool, window: NSWindow?) async -> URL?
    func askName(current: String, window: NSWindow?) async -> String?
}

@MainActor
final class AppKitCommandPrompts: CommandPrompts {
    func confirm(_ prompt: CommandPrompt, window: NSWindow?) async -> Bool {
        let alert = NSAlert()
        switch prompt {
        case .openManyWindows(let count):
            alert.messageText = String(format: L10n.string("Open %lld windows?"), count)
            alert.addButton(withTitle: L10n.string("Open"))
        case .openManyTabs(let count):
            alert.messageText = String(format: L10n.string("Open %lld tabs?"), count)
            alert.addButton(withTitle: L10n.string("Open"))
        case .applyViewToAllFolders:
            alert.messageText = L10n.string("Use this view for all folders?")
            alert.informativeText = L10n.string("Folders that have their own view settings will be reset to this view.")
            alert.addButton(withTitle: L10n.string("Apply"))
        case .confirmTrash(let count):
            alert.messageText = String(format: L10n.string("Move %lld items to the Trash?"), count)
            alert.addButton(withTitle: L10n.string("Move to Trash"))
        case .confirmDelete(let count):
            alert.alertStyle = .critical
            alert.messageText = String(format: L10n.string("Permanently delete %lld items?"), count)
            alert.informativeText = L10n.string("This can't be undone.")
            alert.addButton(withTitle: L10n.string("Delete"))
        default:
            alert.messageText = message(for: prompt)
            alert.addButton(withTitle: L10n.string("OK"))
        }
        alert.addButton(withTitle: L10n.string("Cancel"))
        return await run(alert, window) == .alertFirstButtonReturn
    }

    func inform(_ prompt: CommandPrompt, window: NSWindow?) async {
        let alert = NSAlert()
        alert.messageText = message(for: prompt)
        if case .openFailed(_, _, let detail) = prompt { alert.informativeText = detail }
        if case .ejectFailed(_, _, let detail?) = prompt { alert.informativeText = detail }
        alert.addButton(withTitle: L10n.string("OK"))
        _ = await run(alert, window)
    }

    func brokenLink(_ name: String, window: NSWindow?) async -> BrokenLinkChoice {
        let alert = NSAlert()
        alert.messageText = L10n.string("The original item can't be found")
        alert.informativeText = String(format: L10n.string("'%@' points to an item that no longer exists."), name)
        alert.addButton(withTitle: L10n.string("Fix…"))
        alert.addButton(withTitle: L10n.string("Delete"))
        alert.addButton(withTitle: L10n.string("Cancel"))
        switch await run(alert, window) {
        case .alertFirstButtonReturn: return .fix
        case .alertSecondButtonReturn: return .delete
        default: return .cancel
        }
    }

    func chooseFile(directory: URL?, applicationsOnly: Bool, window: NSWindow?) async -> URL? {
        let panel = NSOpenPanel()
        panel.directoryURL = directory
        panel.canChooseFiles = true
        panel.canChooseDirectories = !applicationsOnly
        panel.allowsMultipleSelection = false
        if applicationsOnly { panel.allowedContentTypes = [.application] }
        let response: NSApplication.ModalResponse
        if let window { response = await panel.beginSheetModal(for: window) } else { response = panel.runModal() }
        return response == .OK ? panel.url : nil
    }

    func askName(current: String, window: NSWindow?) async -> String? {
        let alert = NSAlert()
        alert.messageText = L10n.string("New name:")
        let field = NSTextField(string: current)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.string("Rename"))
        alert.addButton(withTitle: L10n.string("Cancel"))
        alert.window.initialFirstResponder = field
        return await run(alert, window) == .alertFirstButtonReturn ? field.stringValue : nil
    }

    private func message(for prompt: CommandPrompt) -> String {
        switch prompt {
        case .openFailed(let file, let app?, _): String(format: L10n.string("'%@' couldn't be opened with %@."), file, app)
        case .openFailed(let file, nil, _): String(format: L10n.string("'%@' couldn't be opened."), file)
        case .ejectFailed(let volume, let processes, _) where !processes.isEmpty:
            String(format: L10n.string("'%@' can't be ejected because it is in use by %@."), volume,
                   ListFormatter.localizedString(byJoining: processes))
        case .ejectFailed(let volume, _, _): String(format: L10n.string("“%@” couldn't be ejected."), volume)
        case .brokenLink(let name): String(format: L10n.string("'%@' points to an item that no longer exists."), name)
        case .openManyWindows(let count): String(format: L10n.string("Open %lld windows?"), count)
        case .openManyTabs(let count): String(format: L10n.string("Open %lld tabs?"), count)
        case .applyViewToAllFolders: L10n.string("Use this view for all folders?")
        case .confirmTrash(let count): String(format: L10n.string("Move %lld items to the Trash?"), count)
        case .confirmDelete(let count): String(format: L10n.string("Permanently delete %lld items?"), count)
        }
    }

    private func run(_ alert: NSAlert, _ window: NSWindow?) async -> NSApplication.ModalResponse {
        if let window { return await alert.beginSheetModal(for: window) }
        return alert.runModal()
    }
}
