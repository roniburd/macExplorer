import AppKit
import Core
import MacxFS

/// §5.6: files select the base name up to the last ".", while folders, dot-files and names without an extension
/// (or with a trailing dot) select everything. Character-based, so ranges end on grapheme boundaries.
enum BaseNameRange {
    static func range(of name: String, isFolder: Bool) -> Range<String.Index> {
        let whole = name.startIndex..<name.endIndex
        guard !isFolder, let dot = name.lastIndex(of: "."), dot != name.startIndex, name.index(after: dot) != name.endIndex else {
            return whole
        }
        return name.startIndex..<dot
    }

    static func nsRange(of name: String, isFolder: Bool) -> NSRange {
        NSRange(range(of: name, isFolder: isFolder), in: name)
    }
}

enum RenamePrompt: Equatable, Sendable {
    case extensionChanged(from: String, to: String)
    case becomesHidden
}

enum RenameAdvance: Sendable { case none, next, previous }

/// The list a rename field lives in (Details: the table, Icons: the collection view).
@MainActor protocol InlineRenameHost: AnyObject {
    var renameContainer: NSView { get }
    var renameFont: NSFont { get }
    var renameIsMultiline: Bool { get }
    var renameController: InlineRenameController? { get }
    /// Frame of the name text area of `row` in `renameContainer` coordinates; nil when the row isn't laid out.
    func renameFieldFrame(forRow row: Int) -> NSRect?
}

final class RenameField: NSTextField {
    /// Typing undo stays inside the edit (§6.6, QA round 1): AppKit's per-cell undo manager hands ⌘Z it can't
    /// handle to this one, which is empty, never to the window's file-operation stack.
    private let editingUndo = UndoManager()
    override var undoManager: UndoManager? { editingUndo }

    init(frame: NSRect, multiline: Bool, font: NSFont) {
        super.init(frame: frame)
        self.font = font
        isBezeled = true
        bezelStyle = .squareBezel
        isEditable = true
        isSelectable = true
        focusRingType = .exterior
        usesSingleLineMode = !multiline
        cell?.wraps = multiline
        cell?.isScrollable = !multiline
        alignment = multiline ? .center : .natural
        setAccessibilityIdentifier(AXID.renameField)
    }
    required init?(coder: NSCoder) { fatalError("RenameField is created in code") }
}

@MainActor
enum RenamePrompts {
    static func present(_ prompt: RenamePrompt, on window: NSWindow?) async -> Bool {
        let alert = NSAlert()
        switch prompt {
        case .extensionChanged(let from, let to):
            alert.messageText = L10n.string("Are you sure you want to change the extension?")
            alert.informativeText = L10n.string("The file may open in a different app, or not at all.")
            alert.addButton(withTitle: String(format: L10n.string("Use .%@"), to))
            alert.addButton(withTitle: from.isEmpty ? L10n.string("Cancel") : String(format: L10n.string("Keep .%@"), from))
        case .becomesHidden:
            alert.messageText = L10n.string("Names that begin with a dot are hidden.")
            alert.informativeText = L10n.string("The item will be hidden unless hidden items are shown.")
            alert.addButton(withTitle: L10n.string("Use Name"))
            alert.addButton(withTitle: L10n.string("Cancel"))
        }
        let response: NSApplication.ModalResponse
        if let window { response = await alert.beginSheetModal(for: window) } else { response = alert.runModal() }
        return response == .alertFirstButtonReturn
    }
}

/// F2 / ⌘⇧R / Return-as-rename / new items (§5.6). The field sits over the name, follows its item by identity
/// across live updates (relayout) and commits through a rename job (§6.3).
@MainActor
final class InlineRenameController: NSObject, NSTextFieldDelegate {
    private weak var list: (any FileListView)?
    private let folder: FolderModel
    private let environment: CoreEnvironment
    private(set) var field: RenameField?
    private var errorLabel: NSTextField?
    private(set) var editingID: RowID?
    private var originalName = ""
    private var isCommitting = false
    private var isEnding = false
    var origin: OriginID?
    var onEnd: (() -> Void)?
    /// Seam for tests; the default shows the §5.6 alerts as sheets.
    var confirm: @MainActor (RenamePrompt, NSWindow?) async -> Bool = RenamePrompts.present

    var isEditing: Bool { field != nil }
    var currentText: String? { field?.stringValue }
    var errorText: String? { errorLabel?.stringValue }

    init(list: FileListView, folder: FolderModel, environment: CoreEnvironment) {
        self.list = list
        self.folder = folder
        self.environment = environment
        super.init()
    }

    func begin(row: Int) {
        guard row >= 0, row < folder.rowCount, let host = list as? InlineRenameHost else { return }
        if isEditing { finish(notify: false) }
        list?.scrollToRow(row)
        host.renameContainer.layoutSubtreeIfNeeded()
        guard let frame = host.renameFieldFrame(forRow: row) else { return }
        let name = folder.name(atRow: row)
        editingID = folder.identity(atRow: row)
        originalName = name
        folder.select(.set(IndexSet(integer: row), cursor: row))
        let field = RenameField(frame: frame, multiline: host.renameIsMultiline, font: host.renameFont)
        field.stringValue = name
        field.delegate = self
        host.renameContainer.addSubview(field)
        self.field = field
        field.window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = BaseNameRange.nsRange(of: name, isFolder: folder.entry(atRow: row).kind == .directory)
    }

    func commit(moveToNext: Bool) { commit(advance: moveToNext ? .next : .none) }

    func commit(advance: RenameAdvance, fromBlur: Bool = false) {
        guard let field, let id = editingID, !isCommitting else { return }
        guard let row = folder.row(of: id) else { finish(); return }
        let proposed = field.stringValue
        let neighbor = neighborID(of: row, advance)
        if proposed == originalName {
            finish()
            beginNext(neighbor)
            return
        }
        switch folder.validateName(proposed, renamingRow: row) {
        case .invalid(let problem):
            if fromBlur { finish(); return }   // focus moved away: revert, as Explorer does
            showError(ErrorText.renameProblem(problem, name: proposed))
            NSSound.beep()
        case .ok(let warnings):
            isCommitting = true
            let url = folder.url(atRow: row)
            Task { await self.confirmAndRename(url: url, to: proposed, warnings: warnings, neighbor: neighbor) }
        }
    }

    func cancel() { finish() }

    /// After a ChangeSet: move the field to its item's new row, or close it if the item is gone.
    func relayout() {
        guard isEditing, let id = editingID else { return }
        guard let row = folder.row(of: id), let host = list as? InlineRenameHost, let frame = host.renameFieldFrame(forRow: row) else {
            cancel()
            return
        }
        field?.frame = frame
        errorLabel?.frame.origin = NSPoint(x: frame.minX, y: frame.maxY + 2)
        followName(ofRow: row)
    }

    /// The item was renamed under the field (e.g. Tab/⇧Tab reached it before the async patch of the previous commit
    /// landed): track the current name so a commit never compares against a stale one, and refresh untouched text.
    private func followName(ofRow row: Int) {
        guard let field else { return }
        let name = folder.name(atRow: row)
        guard name != originalName else { return }
        let untouched = field.stringValue == originalName
        originalName = name
        guard untouched else { return }
        field.stringValue = name
        field.currentEditor()?.selectedRange = BaseNameRange.nsRange(of: name, isFolder: folder.entry(atRow: row).kind == .directory)
    }

    // MARK: NSTextFieldDelegate

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)): commit(advance: .none); return true
        case #selector(NSResponder.insertTab(_:)): commit(advance: .next); return true
        case #selector(NSResponder.insertBacktab(_:)): commit(advance: .previous); return true
        case #selector(NSResponder.cancelOperation(_:)): cancel(); return true
        default: return false
        }
    }

    func controlTextDidChange(_ obj: Notification) { hideError() }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard isEditing, !isCommitting, !isEnding else { return }
        commit(advance: .none, fromBlur: true)
    }

    // MARK: private

    private func confirmAndRename(url: URL, to name: String, warnings: [NameWarning], neighbor: RowID?) async {
        for warning in warnings {
            let prompt: RenamePrompt = switch warning {
            case .extensionChanged(let from, let to): .extensionChanged(from: from, to: to)
            case .becomesHidden: .becomesHidden
            }
            guard await confirm(prompt, field?.window) else {
                // Declining keeps editing. Refocus only if the sheet took the editor away, and while still marked as
                // committing: re-focusing a field that is editing restarts editing, and the end-of-edit blur commit
                // would ask again in a loop.
                if let field, field.currentEditor() == nil { field.window?.makeFirstResponder(field) }
                isCommitting = false
                return
            }
        }
        finish()
        _ = await environment.operations.perform(JobRequest(.rename(url, to: name), origin: origin))
        beginNext(neighbor)
    }

    private func neighborID(of row: Int, _ advance: RenameAdvance) -> RowID? {
        switch advance {
        case .none: nil
        case .next: row + 1 < folder.rowCount ? folder.identity(atRow: row + 1) : nil
        case .previous: row > 0 ? folder.identity(atRow: row - 1) : nil
        }
    }

    private func beginNext(_ id: RowID?) {
        guard let id, let row = folder.row(of: id) else { return }
        begin(row: row)
    }

    private func showError(_ text: String) {
        guard let field, let container = field.superview else { return }
        let label = errorLabel ?? NSTextField(labelWithString: "")
        label.stringValue = text
        label.textColor = .systemRed
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.drawsBackground = true
        label.backgroundColor = .controlBackgroundColor
        label.sizeToFit()
        label.frame.origin = NSPoint(x: field.frame.minX, y: field.frame.maxY + 2)
        if label.superview == nil { container.addSubview(label) }
        errorLabel = label
        NSAccessibility.post(element: label, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func hideError() {
        errorLabel?.removeFromSuperview()
        errorLabel = nil
    }

    private func finish(notify: Bool = true) {
        isEnding = true
        if let field, field.currentEditor() != nil { field.window?.makeFirstResponder(nil) }
        field?.removeFromSuperview()
        hideError()
        field = nil
        editingID = nil
        isCommitting = false
        isEnding = false
        if notify { onEnd?() }
    }
}
