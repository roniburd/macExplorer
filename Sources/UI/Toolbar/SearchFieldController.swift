import AppKit
import Core
import MacxFS

/// Phase 1 search field (§5.2): filters the current folder by name substring (case- and diacritic-insensitive,
/// done off main by FolderModel.setQuery), live as you type; Esc clears; navigation clears it (the new folder's
/// model starts unfiltered). Sort and hidden-items flags of the folder's query are kept.
@MainActor
final class SearchFieldController: NSObject, NSSearchFieldDelegate {
    let field: NSSearchField = FilterSearchField()
    private let session: BrowserSession

    init(session: BrowserSession) {
        self.session = session
        super.init()
        field.setAccessibilityIdentifier(AXID.search)
        field.identifier = NSUserInterfaceItemIdentifier(AXID.search)
        field.placeholderString = L10n.string("Filter")
        field.setAccessibilityLabel(L10n.string("Filter This Folder"))
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.target = self
        field.action = #selector(searchChanged(_:))
        field.delegate = self
    }

    /// Applies the field's text as the folder's filter.
    func textDidChange() {
        let folder = session.folder
        let text = field.stringValue
        guard folder.query.filter != text else { return }
        var query = folder.query
        query.filter = text
        folder.setQuery(query)
    }

    /// The window navigated: the filter clears.
    func folderChanged() {
        if let editor = field.currentEditor() { editor.string = "" }
        field.stringValue = ""
        textDidChange()
    }

    @objc private func searchChanged(_ sender: Any?) { textDidChange() }

    func controlTextDidChange(_ obj: Notification) { textDidChange() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        textView.string = ""
        field.stringValue = ""
        textDidChange()
        return true
    }
}

/// Typing undo stays inside the filter field (§6.6): ⌘Z AppKit's per-cell undo manager can't handle ends in this
/// empty manager, never in the window's file-operation stack (QA round 1).
final class FilterSearchField: NSSearchField {
    private let editingUndo = UndoManager()
    override var undoManager: UndoManager? { editingUndo }
}
