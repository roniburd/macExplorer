import AppKit
import Core
import MacxFS

extension SidebarViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    // MARK: data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        children(of: item as? SidebarItem).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        box(children(of: item as? SidebarItem)[index])
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        switch item as? SidebarItem {
        case .favoritesHeader?, .locationsHeader?, .foldersHeader?: true
        case .folder(let node)?: tree.isExpandable(node)
        default: false
        }
    }

    // MARK: delegate

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? SidebarItem)?.isHeader ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        !((item as? SidebarItem)?.isHeader ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { true }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? SidebarItem else { return nil }
        let header = item.isHeader
        let id = header ? SidebarCellView.headerIdentifier : SidebarCellView.identifier
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? SidebarCellView ?? SidebarCellView(header: header)
        cell.onEject = nil
        switch item {
        case .favoritesHeader:
            cell.configure(title: L10n.string("Favorites"), symbol: nil, dimmed: false, ejectable: false, toolTip: nil)
        case .locationsHeader:
            cell.configure(title: L10n.string("Locations"), symbol: nil, dimmed: false, ejectable: false, toolTip: nil)
        case .foldersHeader:
            cell.configure(title: L10n.string("Folders"), symbol: nil, dimmed: false, ejectable: false, toolTip: nil)
        case .favorite(let favorite):
            let tip = favorite.isStale
                ? String(format: L10n.string("“%@” can't be found. Right-click to locate it."), favorite.name)
                : favorite.url?.path(percentEncoded: false)
            cell.configure(title: favorite.name, symbol: Self.symbol(for: favorite), dimmed: favorite.isStale,
                           ejectable: false, toolTip: tip)
        case .location(let volume):
            cell.configure(title: volume.name, symbol: Self.symbol(for: volume), dimmed: false, ejectable: volume.isEjectable,
                           toolTip: volume.mountPoint.path(percentEncoded: false))
            cell.onEject = { [weak self] in self?.eject(volume) }
        case .iCloudDrive(let url):
            cell.configure(title: L10n.string("iCloud Drive"), symbol: "icloud", dimmed: false, ejectable: false,
                           toolTip: url.path(percentEncoded: false))
        case .cloudStorage(let folder):
            cell.configure(title: folder.name, symbol: "cloud", dimmed: false, ejectable: false,
                           toolTip: folder.url.path(percentEncoded: false))
        case .trash(let url):
            cell.configure(title: L10n.string("Trash"), symbol: "trash", dimmed: false, ejectable: false,
                           toolTip: url.path(percentEncoded: false))
        case .folder(let node):
            cell.configure(title: node.name, symbol: node.isVolumeRoot ? Self.symbol(for: node.volume) : "folder",
                           dimmed: node.isHidden, ejectable: false, toolTip: node.url.path(percentEncoded: false))
        }
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncing, outlineView.selectedRow >= 0 else { return }
        activateRow(outlineView.selectedRow)
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard case .folder(let node)? = notification.userInfo?["NSObject"] as? SidebarItem else { return }
        tree.didExpand(node)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? SidebarItem, item.isHeader, !isSyncing else { return }
        if settings.collapsedSections.contains(item.section) { settings.collapsedSections.remove(item.section) }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? SidebarItem else { return }
        switch item {
        case .folder(let node):
            tree.didCollapse(node)
            // The subtree collapses with it (re-expanding re-reads only the node itself).
            let wasSyncing = isSyncing
            isSyncing = true
            for child in tree.children(of: node) where outlineView.isItemExpanded(box(.folder(child))) {
                outlineView.collapseItem(box(.folder(child)), collapseChildren: true)
            }
            isSyncing = wasSyncing
        case .favoritesHeader, .locationsHeader, .foldersHeader:
            guard !isSyncing, !settings.collapsedSections.contains(item.section) else { return }
            settings.collapsedSections.insert(item.section)
        case .favorite, .location, .iCloudDrive, .cloudStorage, .trash:
            break
        }
    }

    // MARK: drag and drop (§5.4: drag folders between favorites to add them, drag favorites to reorder)

    /// User favorites drag to reorder (a private id, never a file); FOLDERS tree nodes drag as their folder's file
    /// URL, like Explorer's navigation pane (QA round 1). Volume roots, Locations and default favorites don't drag.
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        switch item as? SidebarItem {
        case .favorite(let favorite)? where favorite.defaultKind == nil:
            let writer = NSPasteboardItem()
            writer.setString(favorite.id.uuidString, forType: Self.favoritePasteboardType)
            return writer
        case .folder(let node)? where !node.isRoot:
            return node.url as NSURL
        default:
            return nil
        }
    }

    /// What a right-drag from `row` carries: a tree folder's URL; nil for every other row.
    func secondaryDragURL(row: Int) -> URL? {
        guard case .folder(let node)? = item(atRow: row), !node.isRoot else { return nil }
        return node.url
    }

    /// §5.6 right-drag from the tree: a secondary drag (the drop shows Copy/Move/Alias/Symlink/Cancel).
    func beginSecondaryDrag(row: Int, event: NSEvent) {
        guard let url = secondaryDragURL(row: row) else { return }
        dragSource.begin(event: event, urls: [url], typeIndices: [TypeRegistry.folderIndex], view: outlineView,
                         frame: { [outlineView] _ in outlineView.rect(ofRow: row) }, secondary: true)
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        if case .favoritesHeader? = item as? SidebarItem, index != NSOutlineViewDropOnItemIndex {
            return favoritesDropOperation(info.draggingPasteboard, childIndex: index)
        }
        // P1-36 (§5.4, §5.6): drops onto a tree node, favorite or volume row go through DropTarget.
        if index == NSOutlineViewDropOnItemIndex, let url = folderURL(forDropOnto: item) {
            return fileDropTarget.validate(info, destination: url)
        }
        return []
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        if index == NSOutlineViewDropOnItemIndex, let url = folderURL(forDropOnto: item) {
            return fileDropTarget.perform(info, destination: url, in: outlineView)
        }
        guard case .favoritesHeader? = item as? SidebarItem, index != NSOutlineViewDropOnItemIndex,
              favoritesDropOperation(info.draggingPasteboard, childIndex: index) != [] else { return false }
        let pasteboard = info.draggingPasteboard
        if let id = Self.draggedFavoriteID(pasteboard) {
            moveFavorite(id: id, toChildIndex: index)
        } else {
            let urls = Self.fileURLs(pasteboard)
            Task { await self.addFavorites(urls, atChildIndex: index) }
        }
        return true
    }

    /// The folder a drop *onto* this row lands in: a tree node's URL, a resolved favorite (nil when stale), a volume's
    /// mount point, iCloud Drive, a cloud storage folder or the Trash; nil for section headers.
    func folderURL(forDropOnto item: Any?) -> URL? {
        (item as? SidebarItem)?.url
    }

    /// Between favorites: a dragged favorite moves (reorder), dragged folders link (add). Anything else is refused.
    func favoritesDropOperation(_ pasteboard: NSPasteboard, childIndex: Int) -> NSDragOperation {
        if Self.draggedFavoriteID(pasteboard) != nil { return .move }
        return Self.fileURLs(pasteboard).isEmpty ? [] : .link
    }

    /// `childIndex` counts rows of the Favorites section (defaults first); user favorites start after the defaults.
    @discardableResult
    func moveFavorite(id: UUID, toChildIndex childIndex: Int) -> Bool {
        let defaults = favorites.rows.filter { $0.defaultKind != nil }.count
        guard let from = settings.favorites.firstIndex(where: { $0.id == id }) else { return false }
        var target = max(0, childIndex - defaults)
        if target > from { target -= 1 }
        return favorites.move(id: id, toUserIndex: target)
    }

    @discardableResult
    func addFavorites(_ urls: [URL], atChildIndex childIndex: Int) async -> Int {
        let defaults = favorites.rows.filter { $0.defaultKind != nil }.count
        return await favorites.add(urls, atUserIndex: max(0, childIndex - defaults))
    }

    static func draggedFavoriteID(_ pasteboard: NSPasteboard) -> UUID? {
        pasteboard.string(forType: favoritePasteboardType).flatMap(UUID.init(uuidString:))
    }

    static func fileURLs(_ pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    // MARK: symbols

    static func symbol(for favorite: SidebarFavorite) -> String {
        switch favorite.defaultKind {
        case .home?: "house"
        case .desktop?: "menubar.dock.rectangle"
        case .documents?: "doc"
        case .downloads?: "arrow.down.circle"
        case .applications?: "square.grid.3x3"
        case nil: "folder"
        }
    }

    static func symbol(for volume: VolumeInfo) -> String {
        if volume.isBoot || volume.isInternal { return "internaldrive" }
        if !volume.isLocal { return "network" }
        return "externaldrive"
    }
}
