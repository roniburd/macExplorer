import AppKit
import os
import Core
import MacxFS

/// NSTableView with the routing the content view needs. P1-35 adds context menus, P1-36 drags and right-drag.
final class FileTableView: NSTableView {
    weak var owner: DetailsViewController?

    override func keyDown(with event: NSEvent) {
        if owner?.handleKeyDown(event) == true { return }
        super.keyDown(with: event)
    }

    /// Model-owned selection (S5-C4): NSTableView's own click tracking never runs.
    override func mouseDown(with event: NSEvent) {
        guard let owner else { return super.mouseDown(with: event) }
        owner.handleMouseDown(event)
    }

    override func mouseUp(with event: NSEvent) {
        guard let owner else { return super.mouseUp(with: event) }
        owner.handleMouseUp(event)
    }

    /// ⌘A goes to the content controller's selectAll: (model selection), not NSTableView's built-in one.
    override func selectAll(_ sender: Any?) {
        _ = nextResponder?.tryToPerform(#selector(NSText.selectAll(_:)), with: sender)
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
        let animate = !changes.requiresReloadData && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        ChangeApplier.apply(changes, to: TableUpdateSink(tableView: tableView, animate: animate))
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
        tableView.selectRowIndexes(folder.selection.rows.filteredIndexSet { $0 < tableView.numberOfRows },
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

    func scrollToRow(_ row: Int) {
        guard row >= 0, row < tableView.numberOfRows else { return }
        tableView.scrollRowToVisible(row)
    }

    func topVisibleRow() -> Int? {
        let clip = scrollView.contentView
        let row = tableView.row(at: NSPoint(x: 1, y: clip.bounds.minY + clip.contentInsets.top + 1))
        return row >= 0 ? row : nil
    }

    func visibleRows() -> Range<Int> {
        let range = tableView.rows(in: tableView.visibleRect)
        guard range.location != NSNotFound, range.length > 0 else { return 0..<0 }
        return range.location..<(range.location + range.length)
    }

    // MARK: scrolling and anchor (§4.3)

    func scrollRowToTop(_ row: Int) {
        let clip = scrollView.contentView
        var origin = clip.bounds.origin
        origin.y = (row > 0 && row < tableView.numberOfRows ? tableView.rect(ofRow: row).minY : 0) - clip.contentInsets.top
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
        return Set(visibleRows().filter { $0 < folder.rowCount }.map { folder.identity(atRow: $0) })
    }

    // MARK: keys

    func handleKeyDown(_ event: NSEvent) -> Bool {
        if KeyRouter.handle(event, focus: .content, returnKey: settings.returnKey, from: tableView) {
            typeSelect.reset()
            return true
        }
        guard let folder else { return false }
        defer { reloadSelectionDrawing() }   // mirror at once, also when hosted without ContentViewController
        return ListKeys.handle(event, folder: folder, list: self, pageSize: max(1, visibleRows().count - 1),
                               navigate: SelectionController.linearNavigator(rowCount: folder.rowCount), typeSelect: typeSelect)
    }

    func handleMouseDown(_ event: NSEvent) {
        view.window?.makeFirstResponder(tableView)
        guard let folder else { return }
        let row = tableView.row(at: tableView.convert(event.locationInWindow, from: nil))
        mouse.mouseDown(row: row >= 0 ? row : nil, event: event, folder: folder, from: tableView)
        reloadSelectionDrawing()
    }

    func handleMouseUp(_ event: NSEvent) {
        guard let folder else { return }
        mouse.mouseUp(folder: folder)
        reloadSelectionDrawing()
    }

    // MARK: columns

    func rebuildColumns() {
        isRebuildingColumns = true
        defer { isRebuildingColumns = false }
        for column in tableView.tableColumns { tableView.removeTableColumn(column) }
        for setting in DetailsColumns.normalized(settings.columns) {
            let column = NSTableColumn(identifier: DetailsColumns.identifier(setting.id))
            column.title = DetailsColumns.title(setting.id)
            column.minWidth = DetailsColumns.minWidth(setting.id)
            column.width = setting.width
            column.isHidden = !setting.visible
            column.resizingMask = .userResizingMask
            column.headerCell.alignment = setting.id == .size ? .right : .left
            tableView.addTableColumn(column)
        }
        tableView.headerView?.menu = DetailsColumns.headerMenu(columns: settings.columns, target: self,
                                                               action: #selector(toggleColumn(_:)))
        updateSortIndicator(folder?.query.sort ?? settings.sort)
    }

    @objc func toggleColumn(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = ColumnID(rawValue: raw) else { return }
        settings.columns = DetailsColumns.toggling(DetailsColumns.settings(fromTableColumns: tableView.tableColumns), id)
        rebuildColumns()
    }

    @objc private func columnsChanged(_ note: Notification) {
        guard !isRebuildingColumns else { return }
        settings.columns = DetailsColumns.settings(fromTableColumns: tableView.tableColumns)
    }

    private func updateSortIndicator(_ sort: MacxFS.SortDescriptor) {
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
        var query = folder.query
        query.sort = next
        folder.setQuery(query)
        settings.sort = next
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

    func numberOfRows(in tableView: NSTableView) -> Int { folder?.rowCount ?? 0 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let folder, let tableColumn, let id = DetailsColumns.columnID(tableColumn.identifier), row < folder.rowCount else {
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
        isSyncingSelection ? proposed : (folder?.selection.rows ?? [])
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
        let rows = visibleRows()
        guard !rows.isEmpty else { return }
        tableView.reloadData(forRowIndexes: IndexSet(integersIn: rows), columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
    }
}

extension DetailsViewController: InlineRenameHost {
    var renameContainer: NSView { tableView }
    var renameFont: NSFont { CellStyle.font }
    var renameIsMultiline: Bool { false }

    func renameFieldFrame(forRow row: Int) -> NSRect? {
        let column = tableView.column(withIdentifier: DetailsColumns.identifier(.name))
        guard column >= 0, row >= 0, row < tableView.numberOfRows else { return nil }
        let cell = tableView.frameOfCell(atColumn: column, row: row)
        let inset = CGFloat(iconPoints) + 5
        let height: CGFloat = max(20, min(cell.height, 22))
        return NSRect(x: cell.minX + inset, y: cell.midY - height / 2, width: max(cell.width - inset, 60), height: height)
    }
}
