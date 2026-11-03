import AppKit
import Core
import MacxFS

/// The sidebar (§5.4): one source-list NSOutlineView with FAVORITES, LOCATIONS and FOLDERS sections. Rows navigate the
/// window's session; commands act on the focused row (`focusContext` / `commandTarget`), never on the content
/// selection. Section collapse state persists in `Settings.collapsedSections`.
@MainActor
final class SidebarViewController: CommandHandlingViewController {
    static let favoritePasteboardType = NSPasteboard.PasteboardType("com.macexplorer.favorite")

    let context: UIContext
    let session: BrowserSession
    let outlineView = SidebarOutlineView()
    let tree: FolderTreeController
    let favorites: SidebarFavoritesModel
    /// Locate… picks the new folder (tests replace it). Default: an NSOpenPanel sheet.
    var pickFolder: (_ message: String, _ window: NSWindow?) async -> URL? = SidebarViewController.openPanel

    private(set) var locationItems: [SidebarItem] = []
    private var iCloudDrive: URL?
    private var boxes: [String: (item: SidebarItem, box: AnyObject)] = [:]
    private var settingsLoop: ObservationLoop?
    private var lastSettings: SettingsSnapshot?
    private var tokens: [ObserverToken] = []
    private var keyObserver: (any NSObjectProtocol)?
    private var revealGeneration = 0
    private var revealTask: Task<Void, Never>?
    /// Programmatic selection/expansion: no navigation, no settings writes.
    var isSyncing = false
    /// P1-36 (§5.4, §5.6): drops onto a tree node, favorite or volume row go through DropTarget.
    private(set) lazy var fileDropTarget = DropTarget(context: context, originView: outlineView)

    var environment: CoreEnvironment { context.environment }
    var settings: Settings { environment.settings }

    init(context: UIContext, session: BrowserSession) {
        self.context = context
        self.session = session
        self.tree = FolderTreeController(readers: context.environment.readers, showHidden: context.environment.settings.showHidden)
        self.favorites = SidebarFavoritesModel(environment: context.environment,
                                               confinement: SandboxConfinement(root: context.options.root))
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("created in code") }

    // MARK: CommandHandlingViewController

    /// The selected row's section (§5.4); Favorites when nothing is selected.
    override var focusContext: FocusContext { selectedItem?.focusContext ?? .sidebarFavorites }

    /// The selected row's target; nil when no row is selected.
    override var commandTarget: CommandTarget? { selectedItem?.commandTarget }

    /// Sidebar remaps first (Favorites: Move to Trash → Remove from Favorites); commands the row's section disables
    /// (§5.4: Del, ⇧Del, ⌘X, ⌘D, F2… on Favorites and Locations rows) never reach the handler.
    override func run(_ command: Command, sender: Any?) {
        guard let (effective, target) = resolve(command), let handler else { return }
        handler.perform(effective, target: target, sender: sender)
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let command = MenuValidation.command(for: menuItem.action) else { return false }
        if MenuValidation.blockedByFieldEditor(command, window: viewIfLoaded?.window) { return false }
        guard let (effective, target) = resolve(command), let handler else { return false }
        return handler.canPerform(effective, target: target)
    }

    /// The command and target the handler gets, or nil when the sidebar's focus disables it. With no row selected,
    /// commands that don't act on a row (navigation, window, focus, view) still go through on the current folder
    /// as a sidebar target, so Tab leaves the sidebar and ⌘N/⌘W stay enabled.
    private func resolve(_ command: Command) -> (Command, CommandTarget)? {
        guard let effective = CommandAvailability.effectiveCommand(command, focus: focusContext),
              CommandAvailability.isEnabled(effective, focus: focusContext, state: Self.focusOnlyState) else { return nil }
        if let target = commandTarget { return (effective, target) }
        guard Self.rowIndependent.contains(effective) else { return nil }
        return (effective, .folder(session.folder.directory))
    }

    /// Every state-dependent condition met, so `CommandAvailability.isEnabled` checks only the focus; the handler
    /// checks the real state.
    private static let focusOnlyState = CommandState(
        selectionCount: 1, singleFolderSelected: true, canPaste: true, canUndo: true, canRedo: true, canGoBack: true,
        canGoForward: true, canGoUp: true, targetIsEjectable: true, targetIsPackage: true, folderIsReadOnly: false)

    /// Commands that act on the window or the session, not on a sidebar row.
    static let rowIndependent: Set<Command> = [
        .back, .forward, .up, .refresh, .newWindow, .closeWindow, .showOperations, .focusAddressBar, .focusSearch,
        .cycleFocusForward, .cycleFocusBackward, .undo, .redo, .cancelOperation,
        .viewAsDetails, .viewAsIcons, .iconSizeSmall, .iconSizeMedium, .iconSizeLarge,
        .densityCompact, .densityRegular, .densityComfortable, .toggleHidden, .toggleCommandBar,
        .sortByName, .sortByDateModified, .sortBySize, .sortByKind, .sortByDateCreated, .sortAscending, .sortDescending,
    ]

    // MARK: view

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("macx.sidebar.column"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.floatsGroupRows = false
        outlineView.rowSizeStyle = .default
        outlineView.autoresizesOutlineColumn = false
        outlineView.allowsEmptySelection = true
        outlineView.allowsMultipleSelection = false
        outlineView.setAccessibilityLabel(L10n.string("Sidebar"))
        outlineView.registerForDraggedTypes([Self.favoritePasteboardType] + DropTarget.acceptedTypes)
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(rowClicked(_:))
        outlineView.onActivate = { [weak self] row in self?.activateRow(row) }
        outlineView.menuProvider = { [weak self] row in self?.menu(forRow: row) }
        outlineView.keyHandler = { [weak self] event in
            guard let self else { return false }
            return KeyRouter.handle(event, focus: self.focusContext, returnKey: .open, from: self.outlineView)
        }

        let scroll = NSScrollView()
        scroll.documentView = outlineView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.setAccessibilityIdentifier(AXID.sidebar)
        scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        view = scroll
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tree.onChange = { [weak self] node in self?.treeChanged(node) }
        tree.onDrop = { [weak self] node in self?.boxes[SidebarItem.folder(node).identity] = nil }
        favorites.onChange = { [weak self] in self?.reloadSection(.favoritesHeader) }
        lastSettings = SettingsSnapshot(settings)
        settingsLoop = ObservationLoop({ [weak self] in _ = self.map { SettingsSnapshot($0.settings) } },
                                       onChange: { [weak self] in self?.settingsChanged() })
        tokens.append(environment.volumes.observe { [weak self] _ in self?.volumesChanged() })
        tokens.append(environment.volumes.addReleaseHandler { [weak self] id in self?.volumeReleased(id) })
        tokens.append(session.observe { [weak self] event in
            if case .folderChanged = event { self?.revealCurrentFolder() }
        })
        rebuildLocations()
        updateTreeRoots()
        favorites.refresh()
        refreshICloudDrive()
        outlineView.reloadData()
        syncHeaderExpansion()
        revealCurrentFolder()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard keyObserver == nil, let window = view.window else { return }
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window,
                                                             queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowBecameKey() }
        }
    }

    isolated deinit {
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        settingsLoop?.cancel()
    }

    // MARK: rows

    /// The headers in the outline, in order (Phase 1: always all three).
    var sectionHeaders: [SidebarSection] { SidebarSection.allCases }

    var selectedItem: SidebarItem? { item(atRow: outlineView.selectedRow) }

    func item(atRow row: Int) -> SidebarItem? {
        guard row >= 0 else { return nil }
        return outlineView.item(atRow: row) as? SidebarItem
    }

    /// The outline's object for `item`: one stable box per identity while the value is unchanged.
    func box(_ item: SidebarItem) -> AnyObject {
        let id = item.identity
        if let cached = boxes[id], cached.item == item { return cached.box }
        let box = item as AnyObject
        boxes[id] = (item, box)
        return box
    }

    func children(of item: SidebarItem?) -> [SidebarItem] {
        guard let item else { return sectionHeaders.map(SidebarItem.header) }
        switch item {
        case .favoritesHeader: return favorites.rows.map(SidebarItem.favorite)
        case .locationsHeader: return locationItems
        case .foldersHeader: return tree.roots.map(SidebarItem.folder)
        case .folder(let node): return tree.children(of: node).map(SidebarItem.folder)
        case .favorite, .location, .iCloudDrive: return []
        }
    }

    /// The row for `item`'s current box, or -1.
    func row(of item: SidebarItem) -> Int { outlineView.row(forItem: box(item)) }

    /// Programmatic selection (no navigation).
    func select(row: Int) {
        isSyncing = true
        defer { isSyncing = false }
        if row >= 0 {
            outlineView.selectRowIndexes([row], byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
        } else {
            outlineView.deselectAll(nil)
        }
    }

    // MARK: activation

    /// Click, Return or keyboard selection: navigate to the row's folder (a stale favorite offers Locate…).
    func activateRow(_ row: Int) {
        guard let item = item(atRow: row) else { return }
        activate(item)
    }

    func activate(_ item: SidebarItem) {
        if case .favorite(let favorite) = item, favorite.isStale {
            locate(favorite)
            return
        }
        guard let url = item.url else { return }
        if ChangeBus.key(for: url) == ChangeBus.key(for: session.folder.directory) { return }
        session.navigate(to: url)
    }

    @objc private func rowClicked(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, row == outlineView.selectedRow else { return }
        activateRow(row)
    }

    /// The ⏏ button (and the Eject menu item) go through the command handler like ⌘E.
    func eject(_ volume: VolumeInfo) {
        handler?.perform(.eject, target: .volume(volume), sender: nil)
    }

    func locate(_ favorite: SidebarFavorite) {
        guard favorite.defaultKind == nil else { return }
        let message = String(format: L10n.string("Choose the new location of “%@”."), favorite.name)
        Task {
            guard let url = await pickFolder(message, view.window) else { return }
            await favorites.relocate(id: favorite.id, to: url)
        }
    }

    // MARK: reveal (§5.4: auto-reveal and select the current folder)

    func revealCurrentFolder() {
        guard settings.autoRevealInTree else { return }
        revealGeneration += 1
        let generation = revealGeneration
        let url = session.folder.directory
        revealTask = Task {
            let path = await tree.reveal(url)
            guard generation == revealGeneration else { return }
            applyReveal(path, url: url)
        }
    }

    /// Tests: waits for the latest reveal.
    func revealSettled() async {
        while let task = revealTask {
            await task.value
            if task == revealTask { return }
        }
    }

    private func applyReveal(_ path: [FolderTreeNode]?, url: URL) {
        // Keep a Favorites/Locations row that points at this folder (its Del means "remove", not "trash").
        if let selected = selectedItem, !isTreeItem(selected), let selectedURL = selected.url,
           ChangeBus.key(for: selectedURL) == ChangeBus.key(for: url) {
            expandPath(path)
            return
        }
        guard let path, !settings.collapsedSections.contains(.folders) else {
            if let selected = selectedItem, isTreeItem(selected) { select(row: -1) }
            return
        }
        expandPath(path)
        select(row: row(of: .folder(path[path.count - 1])))
    }

    private func expandPath(_ path: [FolderTreeNode]?) {
        guard let path, !settings.collapsedSections.contains(.folders) else { return }
        isSyncing = true
        defer { isSyncing = false }
        for node in path.dropLast() { outlineView.expandItem(box(.folder(node))) }
    }

    private func isTreeItem(_ item: SidebarItem) -> Bool {
        if case .folder = item { return true }
        return false
    }

    // MARK: updates

    private func treeChanged(_ node: FolderTreeNode?) {
        if let node {
            let item = box(.folder(node))
            guard node.isRoot || outlineView.row(forItem: item) >= 0 else { return }
            reloadPreservingSelection { outlineView.reloadItem(item, reloadChildren: true) }
        } else {
            reloadSection(.foldersHeader)
        }
    }

    func reloadSection(_ header: SidebarItem) {
        reloadPreservingSelection { outlineView.reloadItem(box(header), reloadChildren: true) }
    }

    private func reloadPreservingSelection(_ reload: () -> Void) {
        let selected = selectedItem?.identity
        isSyncing = true
        reload()
        isSyncing = false
        guard let selected, selectedItem?.identity != selected else { return }
        let rows = (0..<outlineView.numberOfRows).first { item(atRow: $0)?.identity == selected }
        select(row: rows ?? -1)
    }

    private func settingsChanged() {
        let now = SettingsSnapshot(settings)
        guard let before = lastSettings, before != now else { return }
        lastSettings = now
        if before.favorites != now.favorites || before.hiddenDefaults != now.hiddenDefaults { favorites.refresh() }
        if before.showICloud != now.showICloud || before.showExternal != now.showExternal {
            rebuildLocations()
            refreshICloudDrive()
        }
        if before.collapsed != now.collapsed { syncHeaderExpansion() }
        if before.showHidden != now.showHidden { tree.showHidden = now.showHidden }
        if !before.autoReveal && now.autoReveal { revealCurrentFolder() }
    }

    private func volumesChanged() {
        rebuildLocations()
        updateTreeRoots()
        favorites.refresh()
    }

    /// The volumes (§5.4). In sandbox mode (--root) the tree has one root, the sandbox folder, so a sandboxed app
    /// or scenario never lists or watches folders outside it.
    func updateTreeRoots() {
        guard let root = context.options.root else { return tree.setVolumes(environment.volumes.browsable) }
        let volume = environment.volumes.volume(for: root) ?? Self.unmappedVolume(at: root)
        tree.setRoots([FolderTreeController.Root(url: root, name: root.lastPathComponent, volume: volume, isVolume: false)])
    }

    private static func unmappedVolume(at url: URL) -> VolumeInfo {
        VolumeInfo(id: .unknown, mountPoint: url, name: url.lastPathComponent, format: "", isBoot: false, isInternal: true,
                   isRemovable: false, isEjectable: false, isLocal: true, isReadOnly: false, isBrowsable: false,
                   totalCapacity: nil,
                   capabilities: VolumeCapabilities(idStable: false, renameExcl: false, clone: false, caseSensitive: false))
    }

    /// The window closed: stop watching and observing.
    func close() {
        tree.stopWatching()
        settingsLoop?.cancel()
        settingsLoop = nil
        tokens = []
        revealTask?.cancel()
    }

    private func volumeReleased(_ id: VolumeID) {
        for root in tree.roots where root.volume.id == id {
            tree.didCollapse(root)
            isSyncing = true
            outlineView.collapseItem(box(.folder(root)), collapseChildren: true)
            isSyncing = false
        }
    }

    private func windowBecameKey() {
        Task { await tree.refreshUnwatched() }
    }

    /// Boot volume first, then the others (Volumes order), iCloud Drive after the boot volume (§5.4 LOCATIONS).
    /// In sandbox mode only volumes mounted inside the root (disk images a test mounted there) are listed.
    func rebuildLocations() {
        let showExternal = settings.showExternalVolumesInSidebar
        let confinement = SandboxConfinement(root: context.options.root)
        var items = environment.volumes.browsable
            .filter { ($0.isBoot || $0.isInternal || showExternal) && confinement.allows($0.mountPoint) }
            .map(SidebarItem.location)
        if settings.showICloudInSidebar, let iCloudDrive, confinement.allows(iCloudDrive) {
            let afterBoot = if case .location(let first)? = items.first, first.isBoot { 1 } else { 0 }
            items.insert(.iCloudDrive(iCloudDrive), at: afterBoot)
        }
        guard items != locationItems else { return }
        locationItems = items
        if isViewLoaded { reloadSection(.locationsHeader) }
    }

    static func iCloudDriveURL(home: URL) -> URL {
        home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)
    }

    /// Whether iCloud Drive exists, checked on a lane (never on main).
    private func refreshICloudDrive() {
        guard settings.showICloudInSidebar else { return }
        let url = Self.iCloudDriveURL(home: settings.home)
        let path = url.path(percentEncoded: false)
        let volume = environment.volumes.volume(for: url)?.id ?? .unknown
        let lanes = environment.lanes
        Task {
            let exists = (try? await lanes.perform(on: volume, .read) { _ in
                var info = stat()
                return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
            }) ?? false
            let next = exists ? url : nil
            guard next != iCloudDrive else { return }
            iCloudDrive = next
            rebuildLocations()
        }
    }

    /// Expands the headers that aren't collapsed in Settings (and collapses the others).
    func syncHeaderExpansion() {
        isSyncing = true
        defer { isSyncing = false }
        for section in sectionHeaders {
            let header = box(.header(section))
            if settings.collapsedSections.contains(section) {
                if outlineView.isItemExpanded(header) { outlineView.collapseItem(header) }
            } else if !outlineView.isItemExpanded(header) {
                outlineView.expandItem(header)
            }
        }
    }

    // MARK: Locate… panel

    private static func openPanel(_ message: String, _ window: NSWindow?) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = message
        panel.prompt = L10n.string("Choose")
        let response: NSApplication.ModalResponse
        if let window {
            response = await withCheckedContinuation { c in panel.beginSheetModal(for: window) { c.resume(returning: $0) } }
        } else {
            response = panel.runModal()
        }
        return response == .OK ? panel.url : nil
    }
}

/// The Settings values the sidebar follows.
struct SettingsSnapshot: Equatable {
    var favorites: [Favorite]
    var hiddenDefaults: Set<DefaultFavorite>
    var showICloud: Bool
    var showExternal: Bool
    var collapsed: Set<SidebarSection>
    var showHidden: Bool
    var autoReveal: Bool

    @MainActor init(_ settings: Settings) {
        favorites = settings.favorites
        hiddenDefaults = settings.hiddenDefaultFavorites
        showICloud = settings.showICloudInSidebar
        showExternal = settings.showExternalVolumesInSidebar
        collapsed = settings.collapsedSections
        showHidden = settings.showHidden
        autoReveal = settings.autoRevealInTree
    }
}
