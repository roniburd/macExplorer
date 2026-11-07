import AppKit
import Core
import MacxFS

/// The Columns (Miller) view (spec §11 Phase 2, P2-19): a horizontal NSScrollView whose document is a horizontal
/// stack (spacing 0) of BrowserColumnControllers, one per `ColumnChain` model. Each column observes its own model;
/// the FileListView methods forward to the active column, and `bind`/`apply` are no-ops (columns bind through
/// `bindChain`). ContentViewController calls `rebuild()` on `.columnsChanged`.
@MainActor
final class ColumnsViewController: NSViewController, FileListView, FocusableList {
    private let context: UIContext
    private(set) var columnControllers: [BrowserColumnController] = []
    private(set) weak var chain: ColumnChain?
    private let stack = NSStackView()
    private let scroll = NSScrollView()
    /// Installed by ContentViewController: the right-click rule against the session's folder (the column under the
    /// click is made active first).
    var contextMenuProvider: ((Int?) -> NSMenu?)?
    var dropTarget: DropTarget?
    /// A middle-click on `row` of a column's model (P2-06).
    var onNewTabGesture: ((NewTabGesture, Int, FolderModel) -> Void)?
    /// A column's empty-state button (Retry, Properties, Privacy Settings).
    var onEmptyStateAction: ((EmptyStateAction, FolderModel) -> Void)?
    /// Hosted on its own (tests, no ContentViewController): the chain's changes rebuild directly.
    private var ownsChainObservation = false

    init(context: UIContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("ColumnsViewController is created in code") }

    override func loadView() {
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.alignment = .top
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .controlBackgroundColor
        scroll.documentView = stack
        scroll.setAccessibilityIdentifier(AXID.columnsView)
        scroll.setAccessibilityLabel(L10n.string("Columns"))
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            stack.topAnchor.constraint(equalTo: clip.topAnchor),
            stack.heightAnchor.constraint(equalTo: clip.heightAnchor),
        ])
        view = scroll
    }

    /// Shows `chain`'s columns (nil: none). When the chain has no other observer (hosted on its own) its
    /// `onChange` rebuilds here; in a window BrowserSession owns `onChange` and ContentViewController calls `rebuild()`.
    func bindChain(_ chain: ColumnChain?) {
        if ownsChainObservation, let old = self.chain, old !== chain { old.onChange = nil }
        ownsChainObservation = false
        self.chain = chain
        if let chain, chain.onChange == nil {
            ownsChainObservation = true
            chain.onChange = { [weak self] in self?.rebuild() }
        }
        rebuild()
    }

    /// Diffs `columnControllers` against `chain.models` by identity: a controller is kept while its model stays at
    /// its index (its vertical scroll and selection drawing stay as they are); the rest are dropped, new ones appended.
    func rebuild() {
        _ = view
        let models = chain?.models ?? []
        let firstResponder = view.window?.firstResponder as? NSView
        let hadFocus = firstResponder.map { $0 === view || $0.isDescendant(of: view) } ?? false
        var kept: [BrowserColumnController] = []
        for (i, m) in models.enumerated() {
            if i < columnControllers.count, columnControllers[i].model === m {
                kept.append(columnControllers[i])
            } else {
                kept.append(BrowserColumnController(context: context, model: m, index: i, owner: self))
            }
        }
        for c in columnControllers where !kept.contains(where: { $0 === c }) {
            c.unbind()
            stack.removeArrangedSubview(c.view)
            c.view.removeFromSuperview()
            c.removeFromParent()
        }
        for c in kept where c.parent == nil {
            addChild(c)
            stack.addArrangedSubview(c.view)
            c.view.heightAnchor.constraint(equalTo: stack.heightAnchor).isActive = true
        }
        columnControllers = kept
        syncFocus(hadFocus: hadFocus)
        scrollActiveIntoView()
        cancelOffscreenIcons()
    }

    /// Focus follows the active column (→/←, ⌘↑, a click in another column): only a column table that is not the
    /// active one gives up focus, so an inline rename field keeps it.
    private func syncFocus(hadFocus: Bool) {
        guard hadFocus, let window = view.window, let active else { return }
        let current = window.firstResponder
        if current === window || current == nil || ((current as? ColumnTableView).map { $0 !== active.tableView } ?? false)
            || (current as? NSView)?.window == nil {
            window.makeFirstResponder(active.tableView)
        }
    }

    /// The active column and the one after it are scrolled into view horizontally.
    func scrollActiveIntoView() {
        guard let chain, columnControllers.indices.contains(chain.activeIndex) else { return }
        view.layoutSubtreeIfNeeded()
        let last = min(chain.activeIndex + 1, columnControllers.count - 1)
        let rect = columnControllers[chain.activeIndex].view.frame.union(columnControllers[last].view.frame)
        stack.scrollToVisible(rect)
    }

    /// A key, click or menu in `column` makes it the active column first.
    func activate(_ column: BrowserColumnController) {
        guard let chain, chain.models.indices.contains(column.index), chain.models[column.index] === column.model,
              chain.activeIndex != column.index else { return }
        chain.activate(column.index)
    }

    /// The column keys (called by the column tables after KeyRouter): →/← move between columns, Return/⌘↓ on the
    /// selected folder whose column is open moves into it, ⌘↑ is the chain's up. false: not a column key here (Return
    /// on a file is the Phase 1 open; ↑/↓ and type-select are the column's own).
    func handleColumnKey(_ chord: KeyChord) -> Bool {
        guard let chain, !chain.models.isEmpty else { return false }
        switch (chord.key, chord.modifiers) {
        case (.right, []): return chain.moveRight()
        case (.left, []): return chain.moveLeft()
        case (.up, [.command]): chain.up(); return true
        case (.returnKey, []), (.down, [.command]): return chain.enterSelectedFolder(of: chain.activeModel)
        default: return false
        }
    }

    /// Tier 1 icon requests not on screen in any column are cancelled.
    func cancelOffscreenIcons() {
        context.icons.cancelFileIcons(notIn: columnControllers.reduce(into: Set<RowID>()) { $0.formUnion($1.visibleRowIDs()) })
    }

    /// Scenario hook `columnsChain`.
    func chainSnapshot() -> (folders: [URL], active: Int) {
        guard let chain else { return ([], 0) }
        return (chain.models.map(\.directory), chain.activeIndex)
    }

    // MARK: FileListView: forwarded to the active column

    /// The active column's folder (`folder` is this as a FolderModel). Columns never show search results.
    var source: (any RowSource)? { chain.flatMap { $0.models.isEmpty ? nil : $0.activeModel } }
    var active: BrowserColumnController? {
        guard let chain, columnControllers.indices.contains(chain.activeIndex) else { return nil }
        return columnControllers[chain.activeIndex]
    }
    var focusView: NSView { active?.tableView ?? view }

    /// Columns bind through `bindChain`; `bind(nil)` (leaving Columns) drops every column. A non-folder source
    /// (search results) also unbinds: ContentViewController shows results in Details instead (P3-09).
    func bind(_ source: (any RowSource)?) {
        if !(source is FolderModel) { bindChain(nil) }
    }

    func apply(_ changes: ChangeSet) {}                  // every column observes its own model
    func reloadSelectionDrawing() { active?.reloadSelectionDrawing() }
    func beginInlineRename(row: Int) { active?.beginInlineRename(row: row) }
    func scrollToRow(_ row: Int) { active?.scrollToRow(row) }
    func topVisibleRow() -> Int? { active?.topVisibleRow() }
    func visibleRows() -> IndexSet { active?.visibleRows() ?? IndexSet() }
    /// Every column redraws its cut rows (the clipboard changed).
    func reloadAllSelectionDrawing() { columnControllers.forEach { $0.reloadSelectionDrawing() } }
}

extension ColumnsViewController: QuickLookSourceList {
    func quickLookSourceFrame(forModelRow row: Int) -> NSRect? { active?.quickLookSourceFrame(forModelRow: row) }
}
