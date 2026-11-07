import AppKit
import Core

/// Asks for a name (Save Search…, Rename Saved Search). Tests install a scripted one on `UIContext.namePrompter`.
@MainActor protocol NamePrompting: AnyObject {
    /// The trimmed name, or nil on Cancel or a blank name.
    func promptForName(title: String, initial: String, on window: NSWindow?) async -> String?
}

/// Sheet with one text field (Save Search…, Rename…). Returns nil on Cancel or a blank name.
@MainActor final class SheetNamePrompter: NamePrompting {
    func promptForName(title: String, initial: String, on window: NSWindow?) async -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: L10n.string("OK"))
        alert.addButton(withTitle: L10n.string("Cancel"))
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        field.setAccessibilityIdentifier(AXID.namePromptField)
        field.setAccessibilityLabel(title)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let response: NSApplication.ModalResponse
        if let window {
            response = await withCheckedContinuation { c in alert.beginSheetModal(for: window) { c.resume(returning: $0) } }
        } else {
            response = alert.runModal()
        }
        guard response == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
