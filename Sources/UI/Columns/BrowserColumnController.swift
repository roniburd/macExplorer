import AppKit
import Core
import MacxFS

/// One Columns-view table (P2-19): routes keys, clicks, drags, right-drags, middle-clicks and the context menu to
/// its BrowserColumnController. NSTableView's own selection tracking never runs (model-owned selection, S5-C4).
final class ColumnTableView: NSTableView, @MainActor NSServicesMenuRequestor, NSSpringLoadingDestination {
    weak var owner: BrowserColumnController?

    override func keyDown(with event: NSEvent) {
        if owner?.handleKeyDown(event) == true { return }
        super.keyDown(with: event)
    }

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

    override func mouseDragged(with event: NSEvent) {
        guard let owner else { return super.mouseDragged(with: event) }
        owner.handleMouseDragged(event)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let owner else { return super.rightMouseDown(with: event) }
        owner.handleRightMouseDown(event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard let owner else { return super.rightMouseDragged(with: event) }
        owner.handleRightMouseDragged(event)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let owner else { return super.rightMouseUp(with: event) }
        owner.handleRightMouseUp(event)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard let owner, event.buttonNumber == 2 else { return super.otherMouseDown(with: event) }
        owner.handleMiddleMouse(at: event.locationInWindow, down: true)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let owner, event.buttonNumber == 2 else { return super.otherMouseUp(with: event) }
        owner.handleMiddleMouse(at: event.locationInWindow, down: false)
    }

    /// ⌘A goes to the content controller's selectAll: (model selection), not NSTableView's built-in one.
    override func selectAll(_ sender: Any?) {
        _ = nextResponder?.tryToPerform(#selector(NSText.selectAll(_:)), with: sender)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        owner?.contextMenu(forRow: row(at: convert(event.locationInWindow, from: nil)))
    }

    func springLoadingEntered(_ draggingInfo: any NSDraggingInfo) -> NSSpringLoadingOptions {
        owner?.springLoadRow(draggingInfo) == nil ? .disabled : .enabled
    }

    func springLoadingUpdated(_ draggingInfo: any NSDraggingInfo) -> NSSpringLoadingOptions {
        owner?.springLoadRow(draggingInfo) == nil ? .disabled : .enabled
    }

    func springLoadingActivated(_ activated: Bool, draggingInfo: any NSDraggingInfo) {
        if activated, let row = owner?.springLoadRow(draggingInfo) { owner?.springLoad(row: row) }
    }

    func springLoadingHighlightChanged(_ draggingInfo: any NSDraggingInfo) {}

    // Services ▸ (§5.6): the selection as file URLs.
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if returnType == nil, sendType == .fileURL || sendType == .string, owner?.model.selection.isEmpty == false { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard let urls = owner?.model.selectedURLs, !urls.isEmpty else { return false }
        pboard.clearContents()
        return pboard.writeObjects(urls.map { $0 as NSURL })
    }
}

/// One column of the Columns view over one FolderModel (P2-19). It observes its own model (`.changes`, `.selection`,
/// `.state`, `.query`) and applies changes like Details; selection goes through SelectionController against its
/// model (identity mapping), so ⌘/⇧-click and ⇧-arrows are Phase 1's. A click, key or menu in the column makes it
/// the chain's active column first. The chain owns and closes the model.
@MainActor
final class BrowserColumnController: NSViewController, FileListView, FocusableList, NSTableViewDataSource, NSTableViewDelegate {
    let context: UIContext
    let model: FolderModel
    let index: Int
    private weak var owner: ColumnsViewController?
    let tableView = ColumnTableView()
    let scrollView = NSScrollView()
    let emptyState = EmptyStateView()
    let resizeHandle = ColumnResizeHandle()
    private var widthConstraint: NSLayoutConstraint?
    private(set) var width: CGFloat
    private var dragStartWidth: CGFloat = 0
    private var token: ObserverToken?
    private var settingsLoop: ObservationLoop?
    private var isSyncingSelection = false
    private var isRestoringScroll = false
    private var lastCutNames: Set<String> = []
    let mouse = ListMouseHandler()
    let typeSelect = TypeSelect()
    private(set) var renameController: InlineRenameController?
    lazy var dragSource = DragSourceController(icons: context.icons)
    private var rightDrag = RightDragTracker()
    private var rightDownEvent: NSEvent?
    private var middleClick = MiddleClickTracker()
    private var bound = true

    var folder: FolderModel? { bound ? model : nil }
    var focusView: NSView { tableView }
    private var settings: Settings { context.environment.settings }

    init(context: UIContext, model: FolderModel, index: Int, owner: ColumnsViewController?) {
        self.context = context
        self.model = model
        self.index = index
        self.owner = owner
        self.width = ColumnWidth.clamp(CGFloat(context.environment.settings.columnWidth))
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("BrowserColumnController is created in code") }

    override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        tableView.owner = self
        tableView.dataSource = self
        tableView.delegate = self
        tableView.headerView = nil
        tableView.style = .fullWidth
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.allowsTypeSelect = false          // TypeSelect (P1-33)
        tableView.rowSizeStyle = .custom
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.doubleAction = nil                // double-click is handled in handleMouseDown (clickCount 2)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("macx.column.name"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.setAccessibilityIdentifier(AXID.column(index))
        tableView.setAccessibilityLabel(Self.displayName(of: model.directory))
        tableView.registerForDraggedTypes(DropTarget.acceptedTypes)
        tableView.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: false)
        tableView.draggingDestinationFeedbackStyle = .regular
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        emptyState.onAction = { [weak self] action in
            guard let self else { return }
            self.owner?.onEmptyStateAction?(action, self.model)
        }
        resizeHandle.onBegin = { [weak self] in self.map { $0.dragStartWidth = $0.width } }
        resizeHandle.onDrag = { [weak self] delta in self.map { $0.setWidth($0.dragStartWidth + delta, save: false) } }
        resizeHandle.onEnd = { [weak self] in self.map { $0.setWidth($0.width, save: true) } }
        resizeHandle.onDoubleClick = { [weak self] in self?.autoFit() }
        for part in [scrollView, emptyState, resizeHandle] as [NSView] {
            part.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(part)
        }
        let widthConstraint = container.widthAnchor.constraint(equalToConstant: width)
        self.widthConstraint = widthConstraint
        NSLayoutConstraint.activate([
            widthConstraint,
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: resizeHandle.leadingAnchor),
            resizeHandle.topAnchor.constraint(equalTo: container.topAnchor),
            resizeHandle.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            resizeHandle.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            resizeHandle.widthAnchor.constraint(equalToConstant: ColumnResizeHandle.width),
            emptyState.topAnchor.constraint(equalTo: scrollView.topAnchor),
            emptyState.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            emptyState.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
        ])
        view = container
        applyDensity()
        settingsLoop = ObservationLoop { [weak self] in
            _ = self?.settings.density
        } onChange: { [weak self] in
            self?.applyDensity()
            self?.reloadVisibleRows()
        }
        token = model.observe { [weak self] event in self?.handle(event) }
        lastCutNames = model.cutNames
        tableView.reloadData()
        restoreScroll(anchor: model.scrollAnchor)
        reloadSelectionDrawing()
        updateEmptyState()
    }

    /// Display name of a column's folder (no file-system call: the path's last component).
    static func displayName(of url: URL) -> String {
        let name = url.lastPathComponent
        return name.isEmpty ? url.path(percentEncoded: false) : name
    }

    /// The chain dropped this column: stop observing, end an inline rename.
    func unbind() {
        bound = false
        token = nil
        settingsLoop?.cancel()
        settingsLoop = nil
        renameController?.cancel()
        renameController = nil
        NotificationCenter.default.removeObserver(self)
    }

    private func handle(_ event: FolderEvent) {
        guard bound else { return }
        switch event {
        case .changes(let changes): apply(changes)
        case .selection: reloadSelectionDrawing()
        case .state, .query: updateEmptyState()
        case .beginRename, .relocate, .groups, .folderSizes, .extendedAttributes: break
        }
    }

    // MARK: FileListView

    /// Columns are bound for their lifetime (the chain owns the model); `bind(nil)` unbinds.
    func bind(_ folder: FolderModel?) {
        if folder == nil { unbind() }
    }

    func apply(_ changes: ChangeSet) {
        guard bound, isViewLoaded else { return }
        let anchor = model.scrollAnchor
        let animate = !changes.requiresReloadData && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        ChangeApplier.apply(changes, to: TableUpdateSink(tableView: tableView, animate: animate))
        renameController?.relayout()
        if changes.requiresReloadData { restoreScroll(anchor: anchor) }
        reloadSelectionDrawing()
        updateEmptyState()
        owner?.cancelOffscreenIcons()
    }

    /// Mirrors the model's selection into the table highlight and redraws cut state when it changed.
    func reloadSelectionDrawing() {
        guard bound, isViewLoaded else { return }
        isSyncingSelection = true
        tableView.selectRowIndexes(model.selection.rows.filteredIndexSet { $0 < tableView.numberOfRows }, byExtendingSelection: false)
        isSyncingSelection = false
        if model.cutNames != lastCutNames {
            lastCutNames = model.cutNames
            reloadVisibleRows()
        }
    }

    func beginInlineRename(row: Int) {
        renameController?.cancel()
        let controller = InlineRenameController(list: self, folder: model, environment: context.environment)
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
        let row = tableView.row(at: NSPoint(x: 1, y: max(0, clip.bounds.minY + clip.contentInsets.top + 1)))
        return row >= 0 ? row : nil
    }

    func visibleRows() -> IndexSet {
        let range = tableView.rows(in: tableView.visibleRect)
        guard range.location != NSNotFound, range.length > 0 else { return IndexSet() }
        return IndexSet(integersIn: range.location..<(range.location + range.length))
    }

    /// Quick Look's zoom origin (P2-11): the row's icon on screen, nil when the row is not on screen.
    func quickLookSourceFrame(forModelRow row: Int) -> NSRect? {
        guard let window = view.window, row < tableView.numberOfRows, visibleRows().contains(row),
              let icon = (tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView)?.imageView
        else { return nil }
        return window.convertToScreen(icon.convert(icon.bounds, to: nil))
    }

    func visibleRowIDs() -> Set<RowID> {
        Set(visibleRows().filter { $0 < model.rowCount }.map { model.identity(atRow: $0) })
    }

    // MARK: width (Settings.columnWidth)

    func setWidth(_ proposed: CGFloat, save: Bool) {
        width = ColumnWidth.clamp(proposed)
        widthConstraint?.constant = width
        if save, settings.columnWidth != Double(width) { settings.columnWidth = Double(width) }
    }

    /// Double-click on the handle: the widest shown (display) name among the first 2,000 rows, measured with the cell font.
    func autoFit() {
        let count = min(model.rowCount, ColumnWidth.fitSampleLimit)
        setWidth(ColumnWidth.fit(names: (0..<count).map { model.displayName(atRow: $0) }, font: CellStyle.font), save: true)
    }

    // MARK: scrolling

    private func restoreScroll(anchor: RowID?) {
        isRestoringScroll = true
        defer { isRestoringScroll = false }
        let clip = scrollView.contentView
        var origin = clip.bounds.origin
        let row = anchor.flatMap { model.row(of: $0) } ?? 0
        origin.y = (row > 0 && row < tableView.numberOfRows ? tableView.rect(ofRow: row).minY : 0) - clip.contentInsets.top
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }

    @objc private func clipBoundsChanged(_ note: Notification) {
        guard bound, !isRestoringScroll else { return }
        if let top = topVisibleRow(), top > 0, top < model.rowCount { model.scrollAnchor = model.identity(atRow: top) } else {
            model.scrollAnchor = nil
        }
        owner?.cancelOffscreenIcons()
    }

    // MARK: keys

    /// KeyRouter (alternates, e.g. Return → open, which moves into the open child column), then the column keys
    /// (→/←, Return/⌘↓, ⌘↑), then the Phase 1 selection keys and type-select within this column.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard bound else { return false }
        owner?.activate(self)
        if KeyRouter.handle(event, focus: .content, returnKey: settings.returnKey, from: tableView,
                            typeSelectActive: typeSelect.isCollecting(in: model)) {
            typeSelect.reset()
            return true
        }
        if let chord = KeyEventTranslator.chord(for: event), owner?.handleColumnKey(chord) == true {
            typeSelect.reset()
            return true
        }
        defer { reloadSelectionDrawing() }
        return ListKeys.handle(event, folder: model, list: self, pageSize: max(1, visibleRows().count - 1),
                               navigate: SelectionController.linearNavigator(rowCount: model.rowCount), typeSelect: typeSelect)
    }

    // MARK: mouse

    func handleMouseDown(_ event: NSEvent) {
        guard bound else { return }
        owner?.activate(self)
        view.window?.makeFirstResponder(tableView)
        let row = tableView.row(at: tableView.convert(event.locationInWindow, from: nil))
        mouse.mouseDown(row: row >= 0 && row < model.rowCount ? row : nil, event: event, folder: model, from: tableView)
        reloadSelectionDrawing()
    }

    func handleMouseUp(_ event: NSEvent) {
        guard bound else { return }
        mouse.mouseUp(folder: model)
        reloadSelectionDrawing()
    }

    /// Button 2: press and release on the same row asks for a new tab (P2-06); the selection is not touched.
    func handleMiddleMouse(at windowPoint: NSPoint, down: Bool) {
        let hit = tableView.row(at: tableView.convert(windowPoint, from: nil))
        let row = hit >= 0 ? hit : nil
        if down {
            middleClick.mouseDown(row: row)
        } else if let row = middleClick.mouseUp(row: row) {
            owner?.onNewTabGesture?(.middleClick, row, model)
        }
    }

    /// Right-click rule (§5.6) against this column's model: the column becomes active first, so the menu's
    /// commands target it.
    func contextMenu(forRow row: Int) -> NSMenu? {
        guard bound else { return nil }
        owner?.activate(self)
        return owner?.contextMenuProvider?(row >= 0 && row < model.rowCount ? row : nil)
    }

    // MARK: drags (P1-36)

    func handleMouseDragged(_ event: NSEvent) {
        guard let start = mouse.mouseDownWindowPoint, let row = mouse.mouseDownRow, !dragSource.isDragging,
              RightDragTracker.exceedsThreshold(from: start, to: event.locationInWindow) else { return }
        mouse.cancelPendingForDrag()
        let rows = model.selection.rows.contains(row) ? model.selection.rows : IndexSet(integer: row)
        dragSource.begin(event: event, rows: rows, folder: model, view: tableView, rowFrame: { [tableView] in tableView.rect(ofRow: $0) },
                         secondary: false)
    }

    func handleRightMouseDown(_ event: NSEvent) {
        rightDrag.rightMouseDown(at: event.locationInWindow)
        rightDownEvent = event
    }

    func handleRightMouseDragged(_ event: NSEvent) {
        guard rightDrag.rightMouseDragged(to: event.locationInWindow) == .beginDrag, let down = rightDownEvent else { return }
        let row = tableView.row(at: tableView.convert(down.locationInWindow, from: nil))
        guard row >= 0, row < model.rowCount else { return }
        owner?.activate(self)
        if !model.selection.rows.contains(row) { model.select(.set(IndexSet(integer: row), cursor: row)) }
        reloadSelectionDrawing()
        dragSource.begin(event: event, rows: model.selection.rows, folder: model, view: tableView,
                         rowFrame: { [tableView] in tableView.rect(ofRow: $0) }, secondary: true)
    }

    func handleRightMouseUp(_ event: NSEvent) {
        if case .showMenu = rightDrag.rightMouseUp(at: event.locationInWindow), let down = rightDownEvent,
           let menu = tableView.menu(for: down) {
            NSMenu.popUpContextMenu(menu, with: down, for: tableView)
        }
        rightDownEvent = nil
    }

    /// Spring-loading over a folder row opens it as the next column (the row is selected in this column).
    func springLoadRow(_ info: any NSDraggingInfo) -> Int? {
        let row = tableView.row(at: tableView.convert(info.draggingLocation, from: nil))
        guard bound, row >= 0, row < model.rowCount, SpringLoadPolicy.opens(model.entry(atRow: row).kind) else { return nil }
        return row
    }

    func springLoad(row: Int) {
        guard bound, row < model.rowCount else { return }
        owner?.activate(self)
        model.select(.set(IndexSet(integer: row), cursor: row))
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard bound, let dropTarget = owner?.dropTarget else { return [] }
        let result = DropRetarget.destination(row: row, onRow: dropOperation == .on, folder: model)
        if result.retargetToFolder { tableView.setDropRow(-1, dropOperation: .on) }   // the column's folder
        return dropTarget.validate(info, destination: result.url)
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard bound, let dropTarget = owner?.dropTarget else { return false }
        let destination = DropRetarget.destination(row: row, onRow: dropOperation == .on, folder: model)
        return dropTarget.perform(info, destination: destination.url, in: tableView)
    }

    // MARK: data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int { bound ? model.rowCount : 0 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard bound, row < model.rowCount else { return nil }
        let cell = tableView.makeView(withIdentifier: ColumnCellView.reuseID, owner: nil) as? ColumnCellView ?? ColumnCellView()
        let entry = model.entry(atRow: row)
        let name = model.name(atRow: row)
        let rowID = model.identity(atRow: row)
        let scale = Double(view.window?.backingScaleFactor ?? 2)
        cell.configure(name: model.displayName(atRow: row), icon: context.icons.typeIcon(entry.typeIndex, points: ColumnCellView.iconPoints, scale: scale),
                       isFolder: entry.kind == .directory, isCut: model.isCut(row: row), rowID: rowID)
        requestFileIcon(entry: entry, name: name, row: row, rowID: rowID, cell: cell, scale: scale)
        return cell
    }

    /// Only the model's own mirror writes are accepted; built-in proposals never reach the model (S5-C4).
    func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        isSyncingSelection ? proposed : model.selection.rows
    }

    // MARK: helpers

    func updateEmptyState() {
        guard isViewLoaded else { return }
        emptyState.show(bound ? EmptyStateContent.make(state: model.state, folderName: Self.displayName(of: model.directory),
                                                       visibleCount: model.rowCount, filter: model.query.filter) : nil)
    }

    private func requestFileIcon(entry: Entry, name: String, row: Int, rowID: RowID, cell: ColumnCellView, scale: Double) {
        let url = model.url(atRow: row)
        let isVolumeRoot = entry.kind == .directory
            && context.environment.volumes.mountTable.volumes.contains { $0.mountPoint.standardizedFileURL == url.standardizedFileURL }
        guard context.icons.needsFileIcon(entry, name: name, isVolumeRoot: isVolumeRoot) else { return }
        context.icons.fileIcon(for: url, rowID: rowID, points: ColumnCellView.iconPoints, scale: scale) { [weak cell] image in
            guard let cell, cell.rowID == rowID else { return }
            cell.setIcon(image)
        }
    }

    private func applyDensity() {
        tableView.rowHeight = settings.density.rowHeight
    }

    func reloadVisibleRows() {
        let rows = visibleRows()
        guard !rows.isEmpty else { return }
        tableView.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
    }
}

extension BrowserColumnController: InlineRenameHost {
    var renameContainer: NSView { tableView }
    var renameFont: NSFont { CellStyle.font }
    var renameIsMultiline: Bool { false }

    func renameFieldFrame(forRow row: Int) -> NSRect? {
        guard row >= 0, row < tableView.numberOfRows else { return nil }
        let cell = tableView.frameOfCell(atColumn: 0, row: row)
        let inset = CGFloat(ColumnCellView.iconPoints) + 8
        let height: CGFloat = max(20, min(cell.height, 22))
        return NSRect(x: cell.minX + inset, y: cell.midY - height / 2, width: max(cell.width - inset - 16, 60), height: height)
    }
}

extension BrowserColumnController: QuickLookSourceList {}
