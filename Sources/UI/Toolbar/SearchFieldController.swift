import AppKit
import Core
import MacxFS

/// The toolbar search field (§5.2, P3-10): its text goes to the window's SearchController, which filters the folder
/// instantly (This folder by name, the Phase 1 behaviour, now with globs and the query syntax) or searches with the
/// scope bar's scope and mode. Return runs at once; Esc clears a non-empty field, else hands the keyboard back to the
/// content; navigation clears it (`SessionEvent.searchTextChanged`). The placeholder names the folder.
@MainActor
final class SearchFieldController: NSObject, NSSearchFieldDelegate {
    let field: NSSearchField = FilterSearchField()
    let controller: SearchController
    private let session: BrowserSession
    /// Esc on an empty field: the window focuses the content.
    var onEndEditing: (() -> Void)?
    /// The field became or stopped being the first responder (the scope bar shows while it is).
    var onFocusChange: ((Bool) -> Void)?
    private(set) var isEditing = false

    init(session: BrowserSession, controller: SearchController) {
        self.session = session
        self.controller = controller
        super.init()
        field.setAccessibilityIdentifier(AXID.search)
        field.identifier = NSUserInterfaceItemIdentifier(AXID.search)
        field.setAccessibilityLabel(L10n.string("Search"))
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.target = self
        field.action = #selector(searchChanged(_:))
        field.delegate = self
        updatePlaceholder()
    }

    /// Sends the field's text to the search controller.
    func textDidChange() {
        let text = field.stringValue
        if text.isEmpty, !controller.text.isEmpty { controller.clear(); return }
        controller.textDidChange(text)
    }

    /// The session's search changed from outside the field (navigation clears it, Back shows a search).
    func searchTextChanged(_ text: String) {
        if field.stringValue != text {
            if let editor = field.currentEditor() { editor.string = text }
            field.stringValue = text
        }
        controller.adopt(session.searchSpec)
    }

    /// The folder changed: the placeholder names it.
    func folderChanged() { updatePlaceholder() }

    func updatePlaceholder() {
        let name = session.results?.spec?.root.lastPathComponent ?? session.folder.directory.lastPathComponent
        field.placeholderString = SearchStrings.fieldPlaceholder(name.isEmpty ? "/" : name)
    }

    @objc private func searchChanged(_ sender: Any?) { textDidChange() }

    func controlTextDidChange(_ obj: Notification) { textDidChange() }

    func controlTextDidBeginEditing(_ obj: Notification) {
        isEditing = true
        onFocusChange?(true)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        isEditing = false
        onFocusChange?(false)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            controller.textDidChange(field.stringValue)
            controller.commit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if !field.stringValue.isEmpty || controller.hasQuery {
                textView.string = ""
                field.stringValue = ""
                controller.clear()
            } else {
                onEndEditing?()
            }
            return true
        default:
            return false
        }
    }
}

/// Typing undo stays inside the filter field (§6.6): ⌘Z AppKit's per-cell undo manager can't handle ends in this
/// empty manager, never in the window's file-operation stack (QA round 1).
final class FilterSearchField: NSSearchField {
    private let editingUndo = UndoManager()
    override var undoManager: UndoManager? { editingUndo }
}
