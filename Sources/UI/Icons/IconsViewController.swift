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
}

@MainActor
final class IconsViewController: NSViewController, FileListView, FocusableList, NSCollectionViewDataSource, NSCollectionViewDelegate {
    let context: UIContext
    let layout = FileGridLayout()
    let collectionView = FileCollectionView()
    let scrollView = NSScrollView()
    /// What the grid draws (P3-09): a folder or search results. Folder-only features use `folder`.
    private(set) var source: (any RowSource)?
    /// The folder's icon size, from its view state (P2-08). `setIconSize` changes it.
    private(set) lazy var iconSize: IconSize = settings.iconSize
    private var isRestoringScroll = false
    /// A scroll restore asked for before the grid had its width (first mount, a view switch): the row frames, and
    /// so the offset and the visible items, are only known after the next layout pass (QA round 1).
    private var pendingScrollAnchor: RowID??
    private var laidOutWidth: CGFloat = 0
    let mouse = ListMouseHandler()
    let typeSelect = TypeSelect()
    private(set) var renameController: InlineRenameController?
    /// Installed by ContentViewController (P1-35): item under the click, nil for empty space.
    var contextMenuProvider: ((Int?) -> NSMenu?)?
    /// Installed by ContentViewController (P1-36).
    var dropTarget: DropTarget?
    var onSpringLoad: ((URL) -> Void)?
    /// Installed by ContentViewController (P2-06): a middle-click on item `row` (the selection is not touched).
    var onNewTabGesture: ((NewTabGesture, Int) -> Void)?
    private var middleClick = MiddleClickTracker()
    lazy var dragSource = DragSourceController(icons: context.icons)
    var rightDrag = RightDragTracker()
    var rightDownEvent: NSEvent?
    var focusView: NSView { collectionView }
    private var settings: Settings { context.environment.settings }
    private var points: Double { layout.iconSize.points }
    /// Tier 2 (P2-17): Quick Look thumbnails for the visible eligible items, into the shared cache.
    private(set) lazy var thumbnails: ThumbnailScheduler = {
        let scheduler = ThumbnailScheduler(generator: context.makeThumbnailGenerator(), cache: context.thumbnails)
        scheduler.onThumbnail = { [weak self] key in self?.thumbnailArrived(key) }
        return scheduler
    }()
    private var thumbnailRefreshPending = false
    /// The bound folder's volume and path for thumbnail keys, computed once per bind (configure stays cheap).
    private var thumbnailFolder: (volume: VolumeID, directory: String)?
    private var thumbnailSettingLoop: ObservationLoop?

    init(context: UIContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("IconsViewController is created in code") }

    override func loadView() {
        layout.iconSize = iconSize
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
        thumbnailSettingLoop = ObservationLoop({ [weak self] in _ = self?.context.environment.settings.showThumbnails },
                                               onChange: { [weak self] in self?.showThumbnailsChanged() })
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        scheduleThumbnailRefresh()   // the backing scale is known now
    }

    /// The grid's width is final here: a deferred scroll restore runs now, and a width change (columns, so the
    /// visible items) gets a thumbnail pass of its own.
    override func viewDidLayout() {
        super.viewDidLayout()
        let width = scrollView.contentSize.width
        guard width > 0 else { return }
        if let anchor = pendingScrollAnchor {
            pendingScrollAnchor = nil
            collectionView.layoutSubtreeIfNeeded()
            restoreScroll(anchor: anchor)
        }
        if abs(width - laidOutWidth) > 0.5 || laidOutWidth == 0 {
            laidOutWidth = width
            scheduleThumbnailRefresh()
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        thumbnails.cancelAll()
    }

    // MARK: FileListView

    func bind(_ source: (any RowSource)?) {
        renameController?.cancel()
        renameController = nil
        self.source = source
        thumbnailFolder = nil
        pendingScrollAnchor = nil
        layout.itemCount = source?.rowCount ?? 0
        collectionView.reloadData()
        if let source { restoreScroll(anchor: source.scrollAnchor) }
        reloadSelectionDrawing()
        thumbnails.cancelAll()
        scheduleThumbnailRefresh()
    }

    func apply(_ changes: ChangeSet) {
        guard let source else { return }
        layout.itemCount = source.rowCount
        switch GridChangePolicy.plan(changes) {
        case .nothing: break
        case .reloadItems(let rows):
            collectionView.reloadItems(at: Set(rows.filteredIndexSet { $0 < source.rowCount }.map { IndexPath(item: $0, section: 0) }))
        case .reloadAll:
            let anchor = source.scrollAnchor
            collectionView.reloadData()
            restoreScroll(anchor: anchor)
        }
        renameController?.relayout()
        reloadSelectionDrawing()
        context.icons.cancelFileIcons(notIn: Set(visibleRows().filter { $0 < source.rowCount }.map { source.identity(atRow: $0) }))
        scheduleThumbnailRefresh()
    }

    func reloadSelectionDrawing() {
        guard let source else { return }
        let emphasized = isEmphasized
        for case let item as IconItem in collectionView.visibleItems() {
            guard let index = collectionView.indexPath(for: item)?.item, index < source.rowCount else { continue }
            item.applyState(isCut: source.isCut(row: index), isSelected: source.selection.rows.contains(index), emphasized: emphasized)
        }
    }

    func beginInlineRename(row: Int) {
        guard let source else { return }
        renameController?.cancel()
        let controller = InlineRenameController(list: self, source: source, environment: context.environment)
        controller.origin = view.window.map { OriginID(raw: $0.windowNumber) }
        controller.onEnd = { [weak self] in
            guard let self, let window = self.view.window, window.firstResponder === window else { return }
            window.makeFirstResponder(self.collectionView)
        }
        renameController = controller
        controller.begin(row: row)
    }

    /// A pending layout pass (a selection change relayouts the window: status bar, command bar) can leave the
    /// document view at a stale height; `scrollToVisible` then clamps to it and the grid never moves (QA round 2).
    func scrollToRow(_ row: Int) {
        guard row >= 0, row < layout.itemCount else { return }
        collectionView.layoutSubtreeIfNeeded()
        let height = layout.collectionViewContentSize.height
        if collectionView.frame.height < height { collectionView.setFrameSize(NSSize(width: collectionView.frame.width, height: height)) }
        collectionView.scrollToVisible(layout.frame(forItem: row).insetBy(dx: 0, dy: -layout.metrics.spacing.height))
    }

    /// Quick Look's zoom origin (P2-11): the item's frame on screen, nil when it is not on screen. In memory only.
    func quickLookSourceFrame(forModelRow row: Int) -> NSRect? {
        guard let window = view.window, row >= 0, row < layout.itemCount else { return nil }
        let frame = layout.frame(forItem: row)
        guard frame.intersects(collectionView.visibleRect) else { return nil }
        return window.convertToScreen(collectionView.convert(frame, to: nil))
    }

    func topVisibleRow() -> Int? {
        let range = layout.indexes(in: collectionView.visibleRect)
        return range.isEmpty ? nil : range.lowerBound
    }

    func visibleRows() -> IndexSet { IndexSet(integersIn: layout.indexes(in: collectionView.visibleRect)) }

    // MARK: scroll anchor (§4.3)

    private func restoreScroll(anchor: RowID?) {
        guard let source else { return }
        guard scrollView.contentSize.width > 0 else {
            pendingScrollAnchor = .some(anchor)     // no geometry yet: viewDidLayout restores it
            return
        }
        pendingScrollAnchor = nil
        isRestoringScroll = true
        defer { isRestoringScroll = false }
        let row = anchor.flatMap { source.row(of: $0) } ?? 0
        let y = row > 0 && row < layout.itemCount ? layout.frame(forItem: row).minY - layout.metrics.insets.top : 0
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y - scrollView.contentView.contentInsets.top))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    @objc private func clipBoundsChanged(_ note: Notification) {
        scheduleThumbnailRefresh()
        guard !isRestoringScroll, pendingScrollAnchor == nil, let source else { return }
        if let top = topVisibleRow(), top > 0 { source.scrollAnchor = source.identity(atRow: top) } else { source.scrollAnchor = nil }
    }

    // MARK: input

    private var isEmphasized: Bool {
        (view.window?.isKeyWindow ?? false) && view.window?.firstResponder === collectionView
    }

    func handleKeyDown(_ event: NSEvent) -> Bool {
        if KeyRouter.handle(event, focus: source is SearchResultsModel ? .searchResults : .content, returnKey: settings.returnKey, from: collectionView,
                            typeSelectActive: typeSelect.isCollecting(in: folder)) {
            typeSelect.reset()
            return true
        }
        guard let source else { return false }
        // Settle a pending layout pass first (no-op when none): a vertical scroller that appears with the rows takes
        // width and so a column, and arrows must move over the grid as it will be drawn.
        view.layoutSubtreeIfNeeded()
        let page = max(1, visibleRows().count - layout.columns)
        defer { reloadSelectionDrawing() }   // mirror at once, also when hosted without ContentViewController
        return ListKeys.handle(event, source: source, list: self, pageSize: page,
                               navigate: SelectionController.gridNavigator(layout), typeSelect: typeSelect)
    }

    func handleMouseDown(_ event: NSEvent) {
        guard let source else { return }
        view.window?.makeFirstResponder(collectionView)
        let point = collectionView.convert(event.locationInWindow, from: nil)
        if let index = layout.itemIndex(at: point) {
            mouse.mouseDown(row: index, event: event, source: source, from: collectionView)
            reloadSelectionDrawing()
            return
        }
        if event.clickCount >= 2 { return }
        trackRubberBand(from: point, event: event)
    }

    func handleMouseUp(_ event: NSEvent) {
        guard let source else { return }
        mouse.mouseUp(source: source)
        reloadSelectionDrawing()
    }

    /// Button 2: press and release on the same item asks for a new tab (P2-06).
    func handleMiddleMouse(at windowPoint: NSPoint, down: Bool) {
        let index = layout.itemIndex(at: collectionView.convert(windowPoint, from: nil))
        if down {
            middleClick.mouseDown(row: index)
        } else if let row = middleClick.mouseUp(row: index) {
            onNewTabGesture?(.middleClick, row)
        }
    }

    private func trackRubberBand(from start: NSPoint, event: NSEvent) {
        guard let source, let window = collectionView.window else { return }
        let mode = RubberBand.mode(for: event.modifierFlags)
        let base = mode == .replace ? IndexSet() : source.selection.rows
        if mode == .replace { source.select(.none) }
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
        guard let source else { return }
        let hits = RubberBand.hits(in: rect, layout: layout)
        source.select(.set(RubberBand.selection(base: base, hits: hits, mode: mode), cursor: hits.last))
    }

    /// The folder's view state (P2-08): relayout keeping the scroll anchor.
    func setIconSize(_ size: IconSize) {
        iconSize = size
        guard isViewLoaded, layout.iconSize != size else { return }
        let anchor = source?.scrollAnchor
        layout.iconSize = size
        collectionView.reloadData()
        restoreScroll(anchor: anchor)
        scheduleThumbnailRefresh()   // new pixels → new keys; the old size's requests are cancelled
    }

    // MARK: thumbnails (P2-17)

    /// The visible set is recomputed on the next run-loop turn, so a burst of scroll/bounds changes costs one pass.
    func scheduleThumbnailRefresh() {
        guard !thumbnailRefreshPending else { return }
        thumbnailRefreshPending = true
        RunLoop.main.perform { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.thumbnailRefreshPending = false
                self.refreshThumbnails()
            }
        }
    }

    /// Hands the visible eligible items to the scheduler, or cancels everything when thumbnails are off.
    func refreshThumbnails() {
        guard settings.showThumbnails, let source, isViewLoaded, view.window != nil else {
            thumbnails.cancelAll()
            return
        }
        let scale = view.window?.backingScaleFactor ?? 2
        var candidates: [ThumbnailCandidate] = []
        for row in layout.indexes(in: collectionView.visibleRect) where row < source.rowCount {
            guard let key = thumbnailKey(row: row, scale: scale) else { continue }
            candidates.append(ThumbnailCandidate(key: key, url: source.url(atRow: row)))
        }
        thumbnails.updateVisible(candidates, pointSize: CGFloat(points), scale: scale)
    }

    /// The key for row `row`'s thumbnail, nil when the item never gets one. In memory only.
    func thumbnailKey(row: Int, scale: CGFloat) -> ThumbnailKey? {
        guard let source, row < source.rowCount else { return nil }
        let entry = source.entry(atRow: row)
        guard ThumbnailScheduler.isEligible(entry, types: context.environment.types) else { return nil }
        let place: (volume: VolumeID, directory: String)
        if let folder {
            place = thumbnailFolder ?? (folder.volume?.id ?? .unknown, folder.directory.standardizedFileURL.path(percentEncoded: false))
            thumbnailFolder = place
        } else {   // search results span folders: each row's own parent (lexical, no file-system call)
            let parent = source.parentURL(atRow: row)
            place = (context.environment.volumes.volume(for: parent)?.id ?? .unknown, PathCellView.text(parent: parent, home: settings.home).full)
        }
        return ThumbnailKey(volume: place.volume, id: source.identity(atRow: row), directory: place.directory,
                            mtime: entry.mtime, size: entry.size, pixels: Int((CGFloat(points) * scale).rounded()))
    }

    private func thumbnailArrived(_ key: ThumbnailKey) {
        guard let source, let row = source.row(of: key.id),
              let item = collectionView.item(at: IndexPath(item: row, section: 0)) as? IconItem,
              item.rowID == key.id, let image = context.thumbnails.image(key),
              thumbnailKey(row: row, scale: view.window?.backingScaleFactor ?? 2) == key else { return }
        item.setThumbnail(image, key: key, points: points)
    }

    private func showThumbnailsChanged() {
        guard let source else { return }
        if settings.showThumbnails {
            scheduleThumbnailRefresh()
            for case let item as IconItem in collectionView.visibleItems() {   // cached thumbnails show at once
                guard let row = collectionView.indexPath(for: item)?.item, row < source.rowCount else { continue }
                configure(item, row: row)
            }
        } else {
            thumbnails.cancelAll()
            for case let item as IconItem in collectionView.visibleItems() where item.thumbnailKey != nil {
                guard let row = collectionView.indexPath(for: item)?.item, row < source.rowCount else { continue }
                configure(item, row: row)
            }
        }
    }

    /// Scenario hook `thumbnailNames`: the visible items whose cell shows a cached thumbnail, in grid order.
    func thumbnailNames() -> [String] {
        guard let source else { return [] }
        return collectionView.visibleItems().compactMap { item -> (Int, String)? in
            guard let item = item as? IconItem, let key = item.thumbnailKey, context.thumbnails.image(key) != nil,
                  let row = collectionView.indexPath(for: item)?.item, row < source.rowCount else { return nil }
            return (row, source.name(atRow: row))
        }.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// Scenario hook `iconsVisibleNames`: the items in the visible rect, in grid order (geometry only).
    func visibleNames() -> [String] {
        guard let source else { return [] }
        return visibleRows().filter { $0 < source.rowCount }.map { source.name(atRow: $0) }
    }

    // MARK: data source

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { source?.rowCount ?? 0 }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: IconItem.reuseID, for: indexPath) as? IconItem ?? IconItem()
        configure(item, row: indexPath.item)
        return item
    }

    private func configure(_ item: IconItem, row: Int) {
        guard let source, row < source.rowCount else { return }
        let entry = source.entry(atRow: row)
        let name = source.name(atRow: row)
        let scale = Double(view.window?.backingScaleFactor ?? 2)
        let rowID = source.identity(atRow: row)
        let points = self.points
        item.configure(name: source.displayName(atRow: row), icon: context.icons.typeIcon(entry.typeIndex, points: points, scale: scale), points: points,
                       labelWidth: Double(layout.metrics.itemSize.width - 8), isCut: source.isCut(row: row),
                       isSelected: source.selection.rows.contains(row), emphasized: isEmphasized,
                       isDataless: entry.flags.contains(.dataless), rowID: rowID)
        if settings.showThumbnails, let key = thumbnailKey(row: row, scale: CGFloat(scale)), let image = context.thumbnails.image(key) {
            item.setThumbnail(image, key: key, points: points)
            return   // the thumbnail replaces tiers 0/1
        }
        let url = source.url(atRow: row)
        let isVolumeRoot = entry.kind == .directory
            && context.environment.volumes.mountTable.volumes.contains { $0.mountPoint.standardizedFileURL == url.standardizedFileURL }
        guard context.icons.needsFileIcon(entry, name: name, isVolumeRoot: isVolumeRoot) else { return }
        context.icons.fileIcon(for: url, rowID: rowID, points: points, scale: scale) { [weak item] image in
            guard let item, item.rowID == rowID, item.thumbnailKey == nil else { return }   // a thumbnail wins
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
