import AppKit
import os
import Core
import MacxFS

/// NSTableView with the routing the content view needs, incl. drags, right-drag and spring-loading (P1-36).
final class FileTableView: NSTableView, @MainActor NSServicesMenuRequestor, NSSpringLoadingDestination {
    weak var owner: DetailsViewController?

    override func keyDown(with event: NSEvent) {
        if owner?.handleKeyDown(event) == true { return }
        super.keyDown(with: event)
    }

    /// Model-owned selection (S5-C4): NSTableView's own click tracking never runs.
    override func mouseDown(with event: NSEvent) {
        guard let owner else { return super.mouseDown(with: event) }
        if event.modifierFlags.contains(.control) {   // ⌃-click opens the context menu immediately (§5.6)
            if let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
            return
        }
        owner.handleMouseDown(event)
    }

    override func mouseUp(with event: NSEvent) {
        guard let owner else { return super.mouseUp(with: event) }
        owner.handleMouseUp(event)
    }

    // MARK: drags and right-drag (P1-36)

    override func mouseDragged(with event: NSEvent) {
        guard let owner else { return super.mouseDragged(with: event) }
        owner.handleMouseDragged(event)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let owner else { return super.rightMouseDown(with: event) }
        owner.handleRightMouseDown(event)   // no menu yet (§5.6)
    }

    // MARK: middle-click (P2-06)

    override func otherMouseDown(with event: NSEvent) {
        guard let owner, event.buttonNumber == 2 else { return super.otherMouseDown(with: event) }
        owner.handleMiddleMouse(at: event.locationInWindow, down: true)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let owner, event.buttonNumber == 2 else { return super.otherMouseUp(with: event) }
        owner.handleMiddleMouse(at: event.locationInWindow, down: false)
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard let owner else { return super.rightMouseDragged(with: event) }
        owner.handleRightMouseDragged(event)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let owner else { return super.rightMouseUp(with: event) }
        owner.handleRightMouseUp(event)
    }

    func springLoadingEntered(_ draggingInfo: any NSDraggingInfo) -> NSSpringLoadingOptions {
        owner?.springLoadTarget(draggingInfo) == nil ? .disabled : .enabled
    }

    func springLoadingUpdated(_ draggingInfo: any NSDraggingInfo) -> NSSpringLoadingOptions {
        owner?.springLoadTarget(draggingInfo) == nil ? .disabled : .enabled
    }

    func springLoadingActivated(_ activated: Bool, draggingInfo: any NSDraggingInfo) {
        if activated, let url = owner?.springLoadTarget(draggingInfo) { owner?.onSpringLoad?(url) }
    }

    func springLoadingHighlightChanged(_ draggingInfo: any NSDraggingInfo) {}

    /// The row under `point` (table coordinates), -1 for none. Grouped (P2-10), `row(at:)` disagrees with the row
    /// frames AppKit lays out around floating group rows (it is off by the floating header near the top, and
    /// macOS 26's full-width style adds space above each later group row), so this searches the row frames instead;
    /// the space above a group row belongs to it. Ungrouped lists keep `row(at:)`.
    func hitRow(at point: NSPoint) -> Int {
        guard owner?.mapping.isGrouped == true else { return row(at: point) }
        let count = numberOfRows
        guard count > 0, point.y >= 0, point.y < rect(ofRow: count - 1).maxY else { return -1 }
        var lo = 0, hi = count - 1
        while lo < hi {                       // first row whose maxY is below point.y
            let mid = (lo + hi) / 2
            if rect(ofRow: mid).maxY <= point.y { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// ⌘A goes to the content controller's selectAll: (model selection), not NSTableView's built-in one.
    override func selectAll(_ sender: Any?) {
        _ = nextResponder?.tryToPerform(#selector(NSText.selectAll(_:)), with: sender)
    }

    /// Right-click rule (§5.6): ContentViewController.contextMenu(forRow:).
    override func menu(for event: NSEvent) -> NSMenu? {
        owner?.contextMenu(forTableRow: hitRow(at: convert(event.locationInWindow, from: nil)))
    }

    // Services ▸ (§5.6): the selection as file URLs.
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if returnType == nil, sendType == .fileURL || sendType == .string, owner?.folder?.selection.isEmpty == false { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard let urls = owner?.folder?.selectedURLs, !urls.isEmpty else { return false }
        pboard.clearContents()
        return pboard.writeObjects(urls.map { $0 as NSURL })
    }
}

@MainActor
final class DetailsViewController: NSViewController, FileListView, FocusableList, NSTableViewDataSource, NSTableViewDelegate {
    let context: UIContext
    let tableView = FileTableView()
    let scrollView = NSScrollView()
    private(set) var folder: FolderModel?
    private var settingsLoop: ObservationLoop?
    private var isRebuildingColumns = false
    private var isSyncingSelection = false
    private var isRestoringScroll = false
    private var didPaintFirstRows = false
    private var lastCutNames: Set<String> = []
    let mouse = ListMouseHandler()
    let typeSelect = TypeSelect()
    private(set) var renameController: InlineRenameController?
    /// Installed by ContentViewController (P1-35): row under the click, nil for empty space.
    var contextMenuProvider: ((Int?) -> NSMenu?)?
    /// Installed by ContentViewController (P1-36).
    var dropTarget: DropTarget?
    var onSpringLoad: ((URL) -> Void)?
    /// Installed by ContentViewController (P2-06): a middle-click on `row` (the selection is not touched).
    var onNewTabGesture: ((NewTabGesture, Int) -> Void)?
    /// The folder's columns (order, widths, visibility), from its view state (P2-08). `apply(columns:)` sets them.
    private(set) lazy var columns: [ColumnSetting] = DetailsColumns.normalized(settings.columns)
    /// Installed by ContentViewController (P2-08): the user resized, moved, showed or hid a column.
    var onColumnsChanged: (([ColumnSetting]) -> Void)?
    /// Installed by ContentViewController (P2-08): a header click asks for this sort. Without it (a table hosted on
    /// its own) the click sets the folder's query directly.
    var onSortChanged: ((MacxFS.SortDescriptor) -> Void)?
    private var middleClick = MiddleClickTracker()
    /// Group by (P2-10): the folder's groups while it is grouped, and which of them are collapsed. Collapse state is
    /// per window and folder (it resets on navigation, not on a view switch); keys gone after a regroup are dropped.
    private var groupedRows: GroupedRows?
    private var collapsed: Set<GroupKey> = []
    private weak var collapsedFolder: FolderModel?
    /// Table row ⇄ model row. Every conversion between the two in Details goes through this.
    var mapping: RowMapping { groupedRows.map(RowMapping.grouped) ?? .identity(count: folder?.rowCount ?? 0) }
    lazy var dragSource = DragSourceController(icons: context.icons)
    var rightDrag = RightDragTracker()
    var rightDownEvent: NSEvent?

    var focusView: NSView { tableView }
    var iconPoints: Double { settings.density == .comfortable ? 20 : 16 }
    private var settings: Settings { context.environment.settings }

    init(context: UIContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("DetailsViewController is created in code") }

    override func loadView() {
        tableView.owner = self
        tableView.dataSource = self
        tableView.delegate = self
        tableView.style = .fullWidth
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.allowsTypeSelect = false          // TypeSelect (P1-33) folds names off main for big folders
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.rowSizeStyle = .custom
        tableView.intercellSpacing = NSSize(width: 6, height: 0)
        tableView.headerView = NSTableHeaderView()
        tableView.doubleAction = nil                // double-click is handled in handleMouseDown (clickCount 2)
        tableView.setAccessibilityIdentifier(AXID.detailsTable)
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(clipBoundsChanged(_:)), name: NSView.boundsDidChangeNotification,
                           object: scrollView.contentView)
        center.addObserver(self, selector: #selector(columnsChanged(_:)), name: NSTableView.columnDidMoveNotification, object: tableView)
        center.addObserver(self, selector: #selector(columnsChanged(_:)), name: NSTableView.columnDidResizeNotification, object: tableView)
        tableView.registerForDraggedTypes(DropTarget.acceptedTypes)
        tableView.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: false)
        tableView.draggingDestinationFeedbackStyle = .regular
        tableView.floatsGroupRows = true
        view = scrollView
        rebuildColumns()
        applyDensity()
        settingsLoop = ObservationLoop { [weak self] in
            guard let self else { return }
            _ = self.settings.density
            _ = self.settings.dateStyle
        } onChange: { [weak self] in
            self?.applyDensity()
            self?.reloadVisibleRows()
        }
    }

    // MARK: FileListView

    func bind(_ folder: FolderModel?) {
        renameController?.cancel()
        renameController = nil
        self.folder = folder
        if let folder, folder !== collapsedFolder {
            collapsed = []
            collapsedFolder = folder
        }
        setGroups(folder?.groups ?? [])
        didPaintFirstRows = false
        lastCutNames = folder?.cutNames ?? []
        tableView.reloadData()
        if let folder {
            updateSortIndicator(folder.query.sort)
            restoreScroll(anchor: folder.scrollAnchor)
        }
        reloadSelectionDrawing()
    }

    func apply(_ changes: ChangeSet) {
        guard let folder else { return }
        let anchor = folder.scrollAnchor
        if let groupedRows {
            // Grouped (P2-10): every structural change arrives as `.groups` + reset; same-order patches are reloads.
            if groupedRows.tableRowCount != tableView.numberOfRows || changes.requiresReloadData
                || !changes.changes.allSatisfy({ if case .reload = $0 { true } else { false } }) {
                tableView.reloadData()
            } else {
                var rows = IndexSet()
                for case .reload(let r) in changes.changes { rows.formUnion(r) }
                TableUpdateSink(tableView: tableView, animate: false).reloadRows(mapping.tableRows(forModelRows: rows))
            }
        } else {
            let animate = !changes.requiresReloadData && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ChangeApplier.apply(changes, to: TableUpdateSink(tableView: tableView, animate: animate))
        }
        renameController?.relayout()
        if changes.requiresReloadData { restoreScroll(anchor: anchor) }
        reloadSelectionDrawing()
        if !didPaintFirstRows, folder.rowCount > 0 {
            didPaintFirstRows = true
            PerfSignposts.signposter.emitEvent(PerfSignposts.firstPaint)
        }
        context.icons.cancelFileIcons(notIn: visibleRowIDs())
    }

    /// Mirrors the model's selection into the table highlight (S5-C4) and redraws cut state when it changed.
    func reloadSelectionDrawing() {
        guard let folder else { return }
        isSyncingSelection = true
        tableView.selectRowIndexes(mapping.tableRows(forModelRows: folder.selection.rows).filteredIndexSet { $0 < tableView.numberOfRows },
                                   byExtendingSelection: false)
        isSyncingSelection = false
        if folder.cutNames != lastCutNames {
            lastCutNames = folder.cutNames
            reloadVisibleRows()
        }
    }

    func beginInlineRename(row: Int) {
        guard let folder else { return }
        renameController?.cancel()
        let controller = InlineRenameController(list: self, folder: folder, environment: context.environment)
        controller.origin = view.window.map { OriginID(raw: $0.windowNumber) }
        controller.onEnd = { [weak self] in
            guard let self, let window = self.view.window, window.firstResponder === window else { return }
            window.makeFirstResponder(self.tableView)
        }
        renameController = controller
        controller.begin(row: row)
    }

    /// Model row. A row in a collapsed group expands its group first (inline rename and new items call this).
    func scrollToRow(_ row: Int) {
        expandGroup(containingModelRow: row)
        guard let table = mapping.tableRow(forModelRow: row), table < tableView.numberOfRows else { return }
        tableView.scrollRowToVisible(table)
    }

    /// Quick Look's zoom origin (P2-11): the row's icon on screen, nil when the row is not on screen. In memory only.
    func quickLookSourceFrame(forModelRow row: Int) -> NSRect? {
        guard let window = view.window, let table = mapping.tableRow(forModelRow: row), table < tableView.numberOfRows,
              tableView.rows(in: tableView.visibleRect).contains(table) else { return nil }
        let column = tableView.column(withIdentifier: DetailsColumns.identifier(.name))
        guard column >= 0, let icon = (tableView.view(atColumn: column, row: table, makeIfNecessary: false) as? NSTableCellView)?.imageView
        else { return nil }
        return window.convertToScreen(icon.convert(icon.bounds, to: nil))
    }

    /// The first item row at or below the top table row, as a model row.
    func topVisibleRow() -> Int? {
        let clip = scrollView.contentView
        let row = tableView.hitRow(at: NSPoint(x: 1, y: max(0, clip.bounds.minY + clip.contentInsets.top + 1)))
        guard row >= 0 else { return nil }
        if let model = mapping.modelRow(forTableRow: row) { return model }
        return mapping.nearestVisibleModelRow(toTableRow: row, direction: 1)
    }

    /// Model rows from the first to the last visible item (headers excluded).
    func visibleRows() -> Range<Int> {
        let items = visibleTableRows().compactMap { mapping.modelRow(forTableRow: $0) }
        guard let first = items.first, let last = items.last else { return 0..<0 }
        return first..<(last + 1)
    }

    /// Table rows in the visible rect.
    func visibleTableRows() -> Range<Int> {
        let range = tableView.rows(in: tableView.visibleRect)
        guard range.location != NSNotFound, range.length > 0 else { return 0..<0 }
        return range.location..<(range.location + range.length)
    }

    // MARK: scrolling and anchor (§4.3)

    func scrollRowToTop(_ row: Int) {
        let clip = scrollView.contentView
        var origin = clip.bounds.origin
        let table = mapping.tableRow(forModelRow: row) ?? 0
        origin.y = (table > 0 && table < tableView.numberOfRows ? tableView.rect(ofRow: table).minY : 0) - clip.contentInsets.top
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }

    private func restoreScroll(anchor: RowID?) {
        guard let folder else { return }
        isRestoringScroll = true
        defer { isRestoringScroll = false }
        if let anchor, let row = folder.row(of: anchor) { scrollRowToTop(row) } else if anchor == nil { scrollRowToTop(0) }
    }

    @objc private func clipBoundsChanged(_ note: Notification) {
        guard !isRestoringScroll, let folder else { return }
        if let top = topVisibleRow(), top > 0 { folder.scrollAnchor = folder.identity(atRow: top) } else { folder.scrollAnchor = nil }
        context.icons.cancelFileIcons(notIn: visibleRowIDs())
    }

    private func visibleRowIDs() -> Set<RowID> {
        guard let folder else { return [] }
        let mapping = self.mapping
        return Set(visibleTableRows().compactMap { mapping.modelRow(forTableRow: $0) }.filter { $0 < folder.rowCount }
            .map { folder.identity(atRow: $0) })
    }

    // MARK: keys

    func handleKeyDown(_ event: NSEvent) -> Bool {
        if KeyRouter.handle(event, focus: .content, returnKey: settings.returnKey, from: tableView,
                            typeSelectActive: typeSelect.isCollecting) {
            typeSelect.reset()
            return true
        }
        guard let folder else { return false }
        defer { reloadSelectionDrawing() }   // mirror at once, also when hosted without ContentViewController
        if handleGroupKey(event, folder: folder) { return true }
        return ListKeys.handle(event, folder: folder, list: self, pageSize: max(1, visibleTableRows().count - 1),
                               navigate: SelectionController.linearNavigator(rowCount: folder.rowCount), typeSelect: typeSelect,
                               mapping: groupedRows == nil ? nil : mapping)
    }

    func handleMouseDown(_ event: NSEvent) {
        view.window?.makeFirstResponder(tableView)
        guard let folder else { return }
        let row = tableView.hitRow(at: tableView.convert(event.locationInWindow, from: nil))
        if let group = mapping.groupIndex(forTableRow: row) {      // a header: toggle, never select (P2-10)
            if event.clickCount == 1 { toggleGroup(group) }
            return
        }
        mouse.mouseDown(row: mapping.modelRow(forTableRow: row), event: event, folder: folder, from: tableView)
        reloadSelectionDrawing()
    }

    func handleMouseUp(_ event: NSEvent) {
        guard let folder else { return }
        mouse.mouseUp(folder: folder)
        reloadSelectionDrawing()
    }

    /// Button 2: press and release on the same row asks for a new tab (P2-06).
    func handleMiddleMouse(at windowPoint: NSPoint, down: Bool) {
        let row = mapping.modelRow(forTableRow: tableView.hitRow(at: tableView.convert(windowPoint, from: nil)))
        if down {
            middleClick.mouseDown(row: row)
        } else if let row = middleClick.mouseUp(row: row) {
            onNewTabGesture?(.middleClick, row)
        }
    }

    // MARK: groups (P2-10)

    /// `.groups(runs)` from the folder: the `.changes(.reset)` that follows reloads the table.
    func applyGroups(_ runs: [GroupRun]) {
        setGroups(runs)
    }

    private func setGroups(_ runs: [GroupRun]) {
        guard !runs.isEmpty else { groupedRows = nil; return }
        let present = Set(runs.map(\.key))
        collapsed = collapsed.intersection(present)
        groupedRows = GroupedRows(runs: runs, collapsed: collapsed)
    }

    var groupRuns: [GroupRun] { groupedRows?.runs ?? [] }

    func isCollapsed(group index: Int) -> Bool {
        guard let groupedRows, groupRuns.indices.contains(index) else { return false }
        return groupedRows.collapsed.contains(groupedRows.runs[index].key)
    }

    /// Collapses or expands group `index` (a header click, its disclosure button, ←/→).
    func toggleGroup(_ index: Int) {
        guard groupRuns.indices.contains(index) else { return }
        let key = groupRuns[index].key
        if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
        regroupTable()
    }

    func collapseAllGroups() {
        collapsed = Set(groupRuns.map(\.key))
        regroupTable()
    }

    func expandAllGroups() {
        collapsed = []
        regroupTable()
    }

    /// Before a rename, a scroll to a row or a new item's rename: its group must be visible.
    func expandGroup(containingModelRow row: Int) {
        guard let groupedRows, groupedRows.tableRow(forModelRow: row) == nil,
              let group = groupedRows.group(containingModelRow: row) else { return }
        collapsed.remove(groupedRows.runs[group].key)
        regroupTable()
    }

    private func regroupTable() {
        guard let runs = groupedRows?.runs else { return }
        groupedRows = GroupedRows(runs: runs, collapsed: collapsed)
        tableView.reloadData()
        renameController?.relayout()
        reloadSelectionDrawing()
    }

    private func headerView(_ group: Int) -> NSView {
        let view = tableView.makeView(withIdentifier: GroupHeaderView.reuseID, owner: nil) as? GroupHeaderView ?? GroupHeaderView()
        let run = groupRuns[group]
        view.configure(title: GroupTitles.title(for: run.key), count: run.rows.count, collapsed: isCollapsed(group: group),
                       groupIndex: group)
        view.onToggle = { [weak self] in self?.toggleGroup($0) }
        return view
    }

    /// ← collapses the group of the cursor row, → expands it (grouped, no ⌘/⌥/⌃).
    private func handleGroupKey(_ event: NSEvent, folder: FolderModel) -> Bool {
        guard let groupedRows, let key = NavKey(event.specialKey), key == .left || key == .right,
              event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
              let cursor = folder.selection.cursor.flatMap({ folder.row(of: $0) }),
              let group = groupedRows.group(containingModelRow: cursor) else { return false }
        typeSelect.reset()
        if isCollapsed(group: group) == (key == .right) { toggleGroup(group) }
        return true
    }

    /// A plain, ⌘- or ⇧-click on table row `row` (what mouse-down and mouse-up do together): a header toggles its
    /// group, an item row goes to the selection as its model row.
    func clickTableRow(_ row: Int, modifiers: ClickModifiers) {
        guard let folder else { return }
        if let group = mapping.groupIndex(forTableRow: row) { toggleGroup(group); return }
        switch SelectionController.click(row: mapping.modelRow(forTableRow: row), clickCount: 1, modifiers: modifiers,
                                         selectedRows: folder.selection.rows) {
        case .select(let command), .selectOnMouseUp(let command): folder.select(command)
        case .open, .nothing: break
        }
        reloadSelectionDrawing()
    }

    /// Right-click rule through the mapping. A header gets Collapse All / Expand All, then the empty-space menu.
    func contextMenu(forTableRow row: Int) -> NSMenu? {
        guard mapping.groupIndex(forTableRow: row) != nil else {
            return contextMenuProvider?(row >= 0 ? mapping.modelRow(forTableRow: row) : nil)
        }
        let menu = contextMenuProvider?(nil) ?? NSMenu()
        menu.insertItem(.separator(), at: 0)
        let expand = ClosureMenuItem(title: L10n.string("Expand All Groups")) { [weak self] in self?.expandAllGroups() }
        expand.identifier = NSUserInterfaceItemIdentifier("macx.menu.expandAllGroups")
        menu.insertItem(expand, at: 0)
        let collapse = ClosureMenuItem(title: L10n.string("Collapse All Groups")) { [weak self] in self?.collapseAllGroups() }
        collapse.identifier = NSUserInterfaceItemIdentifier("macx.menu.collapseAllGroups")
        menu.insertItem(collapse, at: 0)
        return menu
    }

    /// Scenario hook `groupHeaderTitles`: "<title> (<count>)" per group.
    func groupHeaderTitles() -> [String] {
        groupRuns.map { "\(GroupTitles.title(for: $0.key)) (\($0.rows.count))" }
    }

    /// Scenario hook `visibleRowNames`: the names of the table's item rows, in order.
    func visibleRowNames() -> [String] {
        guard let folder else { return [] }
        let mapping = self.mapping
        return (0..<mapping.tableRowCount).compactMap { mapping.modelRow(forTableRow: $0) }.filter { $0 < folder.rowCount }
            .map { folder.name(atRow: $0) }
    }

    /// Scenario click target "group:<title>": toggles the group with that title.
    @discardableResult
    func toggleGroup(titled title: String) -> Bool {
        guard let index = groupRuns.firstIndex(where: { GroupTitles.title(for: $0.key) == title }) else { return false }
        toggleGroup(index)
        return true
    }

    // MARK: columns

    func rebuildColumns() {
        isRebuildingColumns = true
        defer { isRebuildingColumns = false }
        for column in tableView.tableColumns { tableView.removeTableColumn(column) }
        for setting in columns where DetailsColumns.offered.contains(setting.id) {
            let column = NSTableColumn(identifier: DetailsColumns.identifier(setting.id))
            column.title = DetailsColumns.title(setting.id)
            column.minWidth = DetailsColumns.minWidth(setting.id)
            column.width = setting.width
            column.isHidden = !setting.visible
            column.resizingMask = .userResizingMask
            column.headerCell.alignment = setting.id == .size ? .right : .left
            tableView.addTableColumn(column)
        }
        tableView.headerView?.menu = DetailsColumns.headerMenu(columns: columns, target: self,
                                                               action: #selector(toggleColumn(_:)))
        updateSortIndicator(folder?.query.sort ?? settings.sort)
    }

    /// The folder's view state (P2-08): its columns (rebuilt only when they differ from what the table shows, so a
    /// resize in progress is never interrupted) and the sort indicator.
    func apply(columns new: [ColumnSetting], sort: MacxFS.SortDescriptor) {
        let normalized = DetailsColumns.normalized(new)
        if normalized != columns {
            columns = normalized
            if isViewLoaded { rebuildColumns() }
        }
        if isViewLoaded { updateSortIndicator(sort) }
    }

    @objc func toggleColumn(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = ColumnID(rawValue: raw) else { return }
        columns = DetailsColumns.toggling(merged(DetailsColumns.settings(fromTableColumns: tableView.tableColumns)), id)
        rebuildColumns()
        onColumnsChanged?(columns)
    }

    @objc private func columnsChanged(_ note: Notification) {
        guard !isRebuildingColumns else { return }
        let next = merged(DetailsColumns.settings(fromTableColumns: tableView.tableColumns))
        guard next != columns else { return }
        columns = next
        onColumnsChanged?(next)
    }

    /// The table only holds the offered columns: the others keep their stored width and visibility.
    private func merged(_ shown: [ColumnSetting]) -> [ColumnSetting] {
        let offered = Set(DetailsColumns.offered)
        let stored = Dictionary(columns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return DetailsColumns.normalized(shown.map { offered.contains($0.id) ? $0 : (stored[$0.id] ?? $0) })
    }

    private func updateSortIndicator(_ sort: MacxFS.SortDescriptor) {
        tableView.highlightedTableColumn = nil
        for column in tableView.tableColumns {
            let sorted = DetailsColumns.columnID(column.identifier)?.sortField == sort.field
            tableView.setIndicatorImage(sorted ? NSImage(named: sort.ascending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator") : nil,
                                        in: column)
            if sorted { tableView.highlightedTableColumn = column }
        }
    }

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard let folder, let id = DetailsColumns.columnID(tableColumn.identifier) else { return }
        let next = DetailsColumns.nextSort(current: folder.query.sort, clicked: id)
        if let onSortChanged {
            onSortChanged(next)          // saved for this folder; the session sets the query
        } else {
            var query = folder.query
            query.sort = next
            folder.setQuery(query)
        }
        updateSortIndicator(next)
    }

    func tableView(_ tableView: NSTableView, sizeToFitWidthOfColumn column: Int) -> CGFloat {
        let tableColumn = tableView.tableColumns[column]
        guard let folder, let id = DetailsColumns.columnID(tableColumn.identifier) else { return tableColumn.width }
        let texts = visibleRows().filter { $0 < folder.rowCount }.map { text(for: id, row: $0) } + [tableColumn.title]
        let extra = id == .name ? iconPoints + 30 : 14
        return CGFloat(max(DetailsColumns.minWidth(id), DetailsColumns.fitWidth(texts: texts, font: CellStyle.font, extra: extra)))
    }

    // MARK: data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int { folder == nil ? 0 : mapping.tableRowCount }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { mapping.groupIndex(forTableRow: row) != nil }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { mapping.groupIndex(forTableRow: row) == nil }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row tableRow: Int) -> NSView? {
        if let group = mapping.groupIndex(forTableRow: tableRow) {
            return tableColumn == nil || tableView.tableColumns.first { !$0.isHidden } === tableColumn ? headerView(group) : nil
        }
        guard let folder, let tableColumn, let id = DetailsColumns.columnID(tableColumn.identifier),
              let row = mapping.modelRow(forTableRow: tableRow), row < folder.rowCount else {
            return nil
        }
        let entry = folder.entry(atRow: row)
        let isCut = folder.isCut(row: row)
        if id == .name {
            let cell = tableView.makeView(withIdentifier: NameCellView.reuseID, owner: nil) as? NameCellView ?? NameCellView()
            let name = folder.name(atRow: row)
            let scale = Double(view.window?.backingScaleFactor ?? 2)
            let rowID = folder.identity(atRow: row)
            cell.configure(name: name, icon: context.icons.typeIcon(entry.typeIndex, points: iconPoints, scale: scale),
                           iconPoints: iconPoints, isCut: isCut, isDataless: entry.flags.contains(.dataless), rowID: rowID)
            requestFileIcon(entry: entry, name: name, row: row, rowID: rowID, cell: cell, scale: scale)
            return cell
        }
        let cell = tableView.makeView(withIdentifier: PlainCellView.reuseID, owner: nil) as? PlainCellView ?? PlainCellView()
        cell.configure(text: text(for: id, row: row), alignment: id == .size ? .right : .left,
                       monospacedDigits: id == .size, isCut: isCut)
        return cell
    }

    /// Only the model's own mirror writes are accepted; built-in proposals never reach the model (S5-C4).
    func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        isSyncingSelection ? proposed : mapping.tableRows(forModelRows: folder?.selection.rows ?? [])
    }

    // MARK: helpers

    func cellView(row: Int, column: ColumnID) -> NSTableCellView? {
        let index = tableView.column(withIdentifier: DetailsColumns.identifier(column))
        guard index >= 0, row < tableView.numberOfRows else { return nil }
        return tableView.view(atColumn: index, row: row, makeIfNecessary: true) as? NSTableCellView
    }

    private func text(for id: ColumnID, row: Int) -> String {
        guard let folder else { return "" }
        let entry = folder.entry(atRow: row)
        switch id {
        case .name: return folder.name(atRow: row)
        case .dateModified: return Formatters.date(nanoseconds: entry.mtime, style: settings.dateStyle)
        case .dateCreated: return Formatters.date(nanoseconds: entry.ctime, style: settings.dateStyle)
        case .size: return Formatters.size(of: entry)
        case .kind: return context.environment.types.localizedDescription(entry.typeIndex)
        case .fileExtension: return Formatters.extensionText(name: folder.name(atRow: row), kind: entry.kind)
        case .tags, .dateLastOpened, .permissions, .owner, .path, .comments: return ""   // P2-16: never shown before then
        }
    }

    private func requestFileIcon(entry: Entry, name: String, row: Int, rowID: RowID, cell: NameCellView, scale: Double) {
        guard let folder else { return }
        let url = folder.url(atRow: row)
        let isVolumeRoot = entry.kind == .directory
            && context.environment.volumes.mountTable.volumes.contains { $0.mountPoint.standardizedFileURL == url.standardizedFileURL }
        guard context.icons.needsFileIcon(entry, name: name, isVolumeRoot: isVolumeRoot) else { return }
        let points = iconPoints
        context.icons.fileIcon(for: url, rowID: rowID, points: points, scale: scale) { [weak cell] image in
            guard let cell, cell.rowID == rowID else { return }
            cell.setIcon(image, points: points)
        }
    }

    private func applyDensity() {
        tableView.rowHeight = settings.density.rowHeight
    }

    func reloadVisibleRows() {
        let rows = visibleTableRows()
        guard !rows.isEmpty else { return }
        tableView.reloadData(forRowIndexes: IndexSet(integersIn: rows), columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
    }
}

extension DetailsViewController: InlineRenameHost {
    var renameContainer: NSView { tableView }
    var renameFont: NSFont { CellStyle.font }
    var renameIsMultiline: Bool { false }

    /// `row` is a model row; nil while its group is collapsed.
    func renameFieldFrame(forRow modelRow: Int) -> NSRect? {
        let column = tableView.column(withIdentifier: DetailsColumns.identifier(.name))
        guard column >= 0, let row = mapping.tableRow(forModelRow: modelRow), row < tableView.numberOfRows else { return nil }
        let cell = tableView.frameOfCell(atColumn: column, row: row)
        let inset = CGFloat(iconPoints) + 5
        let height: CGFloat = max(20, min(cell.height, 22))
        return NSRect(x: cell.minX + inset, y: cell.midY - height / 2, width: max(cell.width - inset, 60), height: height)
    }
}
