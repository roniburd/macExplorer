// Sources/UI/Icons/IconsViewController.swift
import AppKit
import Core
import MacxFS

/// NSCollectionView batch updates use separate old and new index spaces, not NSTableView's sequential semantics.
/// So any structural change reloads (O(visible) with FileGridLayout), and pure reloads update in place.
enum GridUpdatePlan: Equatable { case nothing, reloadItems(IndexSet), reloadAll }

enum GridChangePolicy {
    static func plan(_ set: ChangeSet) -> GridUpdatePlan {
        if set.isEmpty { return .nothing }
        var reloads = IndexSet()
        for change in set.changes {
            guard case .reload(let rows) = change else { return .reloadAll }
            reloads.formUnion(rows)
        }
        return .reloadItems(reloads)
    }
}

/// Rubber-band selection (§5.5): plain replaces, ⇧ adds, ⌘ toggles.
@MainActor
enum RubberBand {
    enum Mode: Equatable { case replace, add, toggle }

    static func mode(for flags: NSEvent.ModifierFlags) -> Mode {
        flags.contains(.command) ? .toggle : (flags.contains(.shift) ? .add : .replace)
    }

    static func rect(from a: NSPoint, to b: NSPoint) -> NSRect {
        NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    static func hits(in rect: NSRect, layout: FileGridLayout) -> IndexSet {
        var hits = IndexSet()
        for index in layout.indexes(in: rect) where layout.frame(forItem: index).intersects(rect) { hits.insert(index) }
        return hits
    }

    static func selection(base: IndexSet, hits: IndexSet, mode: Mode) -> IndexSet {
        switch mode {
        case .replace: hits
        case .add: base.union(hits)
        case .toggle: base.symmetricDifference(hits)
        }
    }
}

final class RubberBandView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
    }
    required init?(coder: NSCoder) { fatalError("RubberBandView is created in code") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// NSCollectionView with model-owned selection; clicks and keys go through SelectionController. P1-35 adds
/// context menus, P1-36 drags, right-drag and spring-loading.
final class FileCollectionView: NSCollectionView, NSSpringLoadingDestination {
    weak var owner: IconsViewController?
    override var acceptsFirstResponder: Bool { true }

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

    /// Right-click rule (§5.6): ContentViewController.contextMenu(forRow:).
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let owner else { return nil }
        return owner.contextMenuProvider?(owner.layout.itemIndex(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseUp(with event: NSEvent) {
        guard let owner else { return super.mouseUp(with: event) }
        owner.handleMouseUp(event)
    }

    override func selectAll(_ sender: Any?) {
        _ = nextResponder?.tryToPerform(#selector(NSText.selectAll(_:)), with: sender)
    }

    /// Select All validates where selectAll: runs (the content controller up the chain). NSCollectionView's own
    /// validation disables it because the grid is not `isSelectable` (the model owns the selection). The SDK does
    /// not declare NSCollectionView's validateUserInterfaceItem: to Swift, so other actions reach it via its IMP.
    @objc func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        let action = #selector(NSText.selectAll(_:))
        guard item.action == action else { return superValidate(item) }
        var next = nextResponder
        while let responder = next {
            if responder.responds(to: action) {
                if let validator = responder as? NSMenuItemValidation, let menuItem = item as? NSMenuItem {
                    return validator.validateMenuItem(menuItem)
                }
                return true
            }
            next = responder.nextResponder
        }
        return false
    }

    private func superValidate(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        typealias Validate = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        let selector = #selector(validateUserInterfaceItem(_:))
        guard NSCollectionView.instancesRespond(to: selector),
              let imp = class_getMethodImplementation(NSCollectionView.self, selector) else { return true }
        return unsafeBitCast(imp, to: Validate.self)(self, selector, item as AnyObject)
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
}

@MainActor
final class IconsViewController: NSViewController, FileListView, FocusableList, NSCollectionViewDataSource, NSCollectionViewDelegate {
    let context: UIContext
    let layout = FileGridLayout()
    let collectionView = FileCollectionView()
    let scrollView = NSScrollView()
    private(set) var folder: FolderModel?
    private var settingsLoop: ObservationLoop?
    private var isRestoringScroll = false
    let mouse = ListMouseHandler()
    let typeSelect = TypeSelect()
    private(set) var renameController: InlineRenameController?
    /// Installed by ContentViewController (P1-35): item under the click, nil for empty space.
    var contextMenuProvider: ((Int?) -> NSMenu?)?
    /// Installed by ContentViewController (P1-36).
    var dropTarget: DropTarget?
    var onSpringLoad: ((URL) -> Void)?
    lazy var dragSource = DragSourceController(icons: context.icons)
    var rightDrag = RightDragTracker()
    var rightDownEvent: NSEvent?
    var focusView: NSView { collectionView }
    private var settings: Settings { context.environment.settings }
    private var points: Double { layout.iconSize.points }

    init(context: UIContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("IconsViewController is created in code") }

    override func loadView() {
        layout.iconSize = settings.iconSize
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.owner = self
        collectionView.isSelectable = false
        collectionView.backgroundColors = [.controlBackgroundColor]
        collectionView.register(IconItem.self, forItemWithIdentifier: IconItem.reuseID)
        collectionView.setAccessibilityIdentifier(AXID.iconsGrid)
        collectionView.registerForDraggedTypes(DropTarget.acceptedTypes)
        collectionView.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: true)
        collectionView.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: false)
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        view = scrollView
        settingsLoop = ObservationLoop { [weak self] in
            _ = self?.settings.iconSize
        } onChange: { [weak self] in
            self?.applyIconSize()
        }
    }

    // MARK: FileListView

    func bind(_ folder: FolderModel?) {
        renameController?.cancel()
        renameController = nil
        self.folder = folder
        layout.itemCount = folder?.rowCount ?? 0
        collectionView.reloadData()
        if let folder { restoreScroll(anchor: folder.scrollAnchor) }
        reloadSelectionDrawing()
    }

    func apply(_ changes: ChangeSet) {
        guard let folder else { return }
        layout.itemCount = folder.rowCount
        switch GridChangePolicy.plan(changes) {
        case .nothing: break
        case .reloadItems(let rows):
            collectionView.reloadItems(at: Set(rows.filteredIndexSet { $0 < folder.rowCount }.map { IndexPath(item: $0, section: 0) }))
        case .reloadAll:
            let anchor = folder.scrollAnchor
            collectionView.reloadData()
            restoreScroll(anchor: anchor)
        }
        renameController?.relayout()
        reloadSelectionDrawing()
        context.icons.cancelFileIcons(notIn: Set(visibleRows().filter { $0 < folder.rowCount }.map { folder.identity(atRow: $0) }))
    }

    func reloadSelectionDrawing() {
        guard let folder else { return }
        let emphasized = isEmphasized
        for case let item as IconItem in collectionView.visibleItems() {
            guard let index = collectionView.indexPath(for: item)?.item, index < folder.rowCount else { continue }
            item.applyState(isCut: folder.isCut(row: index), isSelected: folder.selection.rows.contains(index), emphasized: emphasized)
        }
    }

    func beginInlineRename(row: Int) {
        guard let folder else { return }
        renameController?.cancel()
        let controller = InlineRenameController(list: self, folder: folder, environment: context.environment)
        controller.origin = view.window.map { OriginID(raw: $0.windowNumber) }
        controller.onEnd = { [weak self] in
            guard let self, let window = self.view.window, window.firstResponder === window else { return }
            window.makeFirstResponder(self.collectionView)
        }
        renameController = controller
        controller.begin(row: row)
    }

    func scrollToRow(_ row: Int) {
        guard row >= 0, row < layout.itemCount else { return }
        collectionView.scrollToVisible(layout.frame(forItem: row).insetBy(dx: 0, dy: -layout.metrics.spacing.height))
    }

    func topVisibleRow() -> Int? {
        let range = layout.indexes(in: collectionView.visibleRect)
        return range.isEmpty ? nil : range.lowerBound
    }

    func visibleRows() -> Range<Int> { layout.indexes(in: collectionView.visibleRect) }

    // MARK: scroll anchor (§4.3)

    private func restoreScroll(anchor: RowID?) {
        guard let folder else { return }
        isRestoringScroll = true
        defer { isRestoringScroll = false }
        let row = anchor.flatMap { folder.row(of: $0) } ?? 0
        let y = row > 0 && row < layout.itemCount ? layout.frame(forItem: row).minY - layout.metrics.insets.top : 0
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y - scrollView.contentView.contentInsets.top))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    @objc private func clipBoundsChanged(_ note: Notification) {
        guard !isRestoringScroll, let folder else { return }
        if let top = topVisibleRow(), top > 0 { folder.scrollAnchor = folder.identity(atRow: top) } else { folder.scrollAnchor = nil }
    }

    // MARK: input

    private var isEmphasized: Bool {
        (view.window?.isKeyWindow ?? false) && view.window?.firstResponder === collectionView
    }

    func handleKeyDown(_ event: NSEvent) -> Bool {
        if KeyRouter.handle(event, focus: .content, returnKey: settings.returnKey, from: collectionView) {
            typeSelect.reset()
            return true
        }
        guard let folder else { return false }
        let page = max(1, visibleRows().count - layout.columns)
        defer { reloadSelectionDrawing() }   // mirror at once, also when hosted without ContentViewController
        return ListKeys.handle(event, folder: folder, list: self, pageSize: page,
                               navigate: SelectionController.gridNavigator(layout), typeSelect: typeSelect)
    }

    func handleMouseDown(_ event: NSEvent) {
        guard let folder else { return }
        view.window?.makeFirstResponder(collectionView)
        let point = collectionView.convert(event.locationInWindow, from: nil)
        if let index = layout.itemIndex(at: point) {
            mouse.mouseDown(row: index, event: event, folder: folder, from: collectionView)
            reloadSelectionDrawing()
            return
        }
        if event.clickCount >= 2 { return }
        trackRubberBand(from: point, event: event)
    }

    func handleMouseUp(_ event: NSEvent) {
        guard let folder else { return }
        mouse.mouseUp(folder: folder)
        reloadSelectionDrawing()
    }

    private func trackRubberBand(from start: NSPoint, event: NSEvent) {
        guard let folder, let window = collectionView.window else { return }
        let mode = RubberBand.mode(for: event.modifierFlags)
        let base = mode == .replace ? IndexSet() : folder.selection.rows
        if mode == .replace { folder.select(.none) }
        let overlay = RubberBandView(frame: NSRect(origin: start, size: .zero))
        collectionView.addSubview(overlay)
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { [weak self] next, stop in
            guard let self, let next, next.type == .leftMouseDragged else { stop.pointee = true; return }
            self.collectionView.autoscroll(with: next)
            let rect = RubberBand.rect(from: start, to: self.collectionView.convert(next.locationInWindow, from: nil))
            overlay.frame = rect
            self.applyRubberBand(rect: rect, mode: mode, base: base)
        }
        overlay.removeFromSuperview()
    }

    func applyRubberBand(rect: NSRect, mode: RubberBand.Mode, base: IndexSet) {
        guard let folder else { return }
        let hits = RubberBand.hits(in: rect, layout: layout)
        folder.select(.set(RubberBand.selection(base: base, hits: hits, mode: mode), cursor: hits.last))
    }

    private func applyIconSize() {
        guard layout.iconSize != settings.iconSize else { return }
        let anchor = folder?.scrollAnchor
        layout.iconSize = settings.iconSize
        collectionView.reloadData()
        restoreScroll(anchor: anchor)
    }

    // MARK: data source

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { folder?.rowCount ?? 0 }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: IconItem.reuseID, for: indexPath) as? IconItem ?? IconItem()
        configure(item, row: indexPath.item)
        return item
    }

    private func configure(_ item: IconItem, row: Int) {
        guard let folder, row < folder.rowCount else { return }
        let entry = folder.entry(atRow: row)
        let name = folder.name(atRow: row)
        let scale = Double(view.window?.backingScaleFactor ?? 2)
        let rowID = folder.identity(atRow: row)
        let points = self.points
        item.configure(name: name, icon: context.icons.typeIcon(entry.typeIndex, points: points, scale: scale), points: points,
                       labelWidth: Double(layout.metrics.itemSize.width - 8), isCut: folder.isCut(row: row),
                       isSelected: folder.selection.rows.contains(row), emphasized: isEmphasized,
                       isDataless: entry.flags.contains(.dataless), rowID: rowID)
        let url = folder.url(atRow: row)
        let isVolumeRoot = entry.kind == .directory
            && context.environment.volumes.mountTable.volumes.contains { $0.mountPoint.standardizedFileURL == url.standardizedFileURL }
        guard context.icons.needsFileIcon(entry, name: name, isVolumeRoot: isVolumeRoot) else { return }
        context.icons.fileIcon(for: url, rowID: rowID, points: points, scale: scale) { [weak item] image in
            guard let item, item.rowID == rowID else { return }
            item.setIcon(image, points: points)
        }
    }
}

extension IconsViewController: InlineRenameHost {
    var renameContainer: NSView { collectionView }
    var renameFont: NSFont { CellStyle.smallFont }
    var renameIsMultiline: Bool { true }

    func renameFieldFrame(forRow row: Int) -> NSRect? {
        guard row >= 0, row < layout.itemCount else { return nil }
        let item = layout.frame(forItem: row)
        let top = item.minY + 6 + CGFloat(layout.iconSize.points) + 2
        return NSRect(x: item.minX + 2, y: top, width: item.width - 4, height: GridMetrics.labelHeight + 4)
    }
}
