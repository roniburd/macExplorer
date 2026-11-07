import AppKit
import Core
import MacxFS

/// One browser window (§5.1): unified toolbar (ToolbarController, P1-27), sidebar + content split, per-window session.
@MainActor
public final class BrowserWindowController: NSWindowController, NSWindowDelegate, ScenarioProbe {
    let context: UIContext
    let session: BrowserSession
    let splitViewController: BrowserSplitViewController
    let toolbarController: ToolbarController
    /// The search field's text, scope, mode and filters → the session's search (P3-10).
    let searchController: SearchController
    var scenarioHooks = ScenarioHooks()
    /// Installed by the address bar (P1-27): ⌘L / ⌥D / F4 begin editing it.
    var focusAddressBar: (() -> Void)?
    /// WindowManager drops the window from its list.
    var onClose: (() -> Void)?
    /// Quick Look on Space (P2-11); `installQuickLook` sets it in init.
    var quickLook: QuickLookController!
    let qlBridge = QuickLookPanelBridge()

    private var sessionToken: ObserverToken?
    /// Settings › Advanced "Show the full path in the window title" applies to open windows (P1-30).
    private var titleLoop: ObservationLoop?
    private var fieldEditorUndo: (owner: ObjectIdentifier, manager: UndoManager)?

    init(context: UIContext, initialURL: URL) {
        self.context = context
        self.session = BrowserSession(environment: context.environment, initialURL: initialURL)
        self.splitViewController = BrowserSplitViewController(context: context, session: session)
        self.searchController = SearchController(session: session, settings: context.environment.settings)
        self.toolbarController = ToolbarController(context: context, session: session, searchController: searchController)
        let window = BrowserWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                   backing: .buffered, defer: false)
        super.init(window: window)
        window.isReleasedWhenClosed = false
        window.identifier = BrowserWindowRestoration.identifier
        window.setAccessibilityIdentifier(AXID.window)
        window.minSize = NSSize(width: 520, height: 320)
        TabController.configure(window)
        let toolbar = NSToolbar(identifier: "macx.browser.toolbar")
        toolbar.displayMode = .iconOnly
        if !context.options.isSandboxed { toolbar.autosavesConfiguration = true }
        toolbar.delegate = toolbarController
        toolbar.allowsUserCustomization = true
        window.toolbar = toolbar
        toolbarController.ensureDefaultItems(in: toolbar)
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden     // the address bar shows where we are; the title still names the window
        window.isRestorable = !context.options.isSandboxed
        window.restorationClass = BrowserWindowRestoration.self
        window.delegate = self
        window.contentViewController = splitViewController
        window.setContentSize(NSSize(width: 1000, height: 640))

        // One FileCommandController per window runs every command for the content and the sidebar (P1-35).
        let fileCommands = FileCommandController(context: context, window: self)
        contentPane?.handler = fileCommands
        sidebarPane?.handler = fileCommands

        installToolbarHooks()
        installSearch()
        installNewTabHooks()
        installQuickLook()
        sessionToken = session.observe { [weak self] event in self?.handle(event) }
        folderDidChange()
        titleLoop = ObservationLoop({ [weak self] in _ = self?.context.environment.settings.showFullPathInTitle },
                                    onChange: { [weak self] in self?.updateTitle() })
    }

    required init?(coder: NSCoder) { fatalError("BrowserWindowController is created in code") }

    /// The window number (stable while the window exists); job origins and sheet hosts use it.
    public var origin: OriginID { OriginID(raw: window?.windowNumber ?? 0) }

    public func navigate(to url: URL, selecting name: String? = nil, folderID: UInt64? = nil) {
        session.navigate(to: url, selecting: name, folderID: folderID)
    }

    /// ⌘T and the tab bar's "+" (NSWindow sends newWindowForTab: up the responder chain; the panes never implement
    /// it): a new, selected tab at the end of this window's tab group (P2-05).
    @objc public override func newWindowForTab(_ sender: Any?) {
        let url = TabController.newTabURL(settings: context.environment.settings, options: context.options,
                                          current: session.folder.directory)
        context.windows.openTab(at: url, in: self, select: true)
    }

    /// Opens `urls` as tabs at the end of this window's tab group (P2-06: Open in New Tab, middle-click, ⌘-click,
    /// drops on the New Tab button). With `select`, the first new tab is selected and the rest open behind it;
    /// otherwise every one is a background tab.
    func openTabs(_ urls: [URL], select: Bool = true) {
        for (index, url) in urls.enumerated() {
            context.windows.openTab(at: url, in: self, select: select && index == 0)
        }
    }

    /// The toolbar's address bar (Phase 4 tests submit through it).
    var addressBar: AddressBarView { toolbarController.addressBar }

    /// ⌘L / ⌥D / F4 edit the address; Return/Esc hand the keyboard back to the content; Tab/⇧Tab follow the focus
    /// cycle; scenario address hooks.
    private func installToolbarHooks() {
        let bar = toolbarController.addressBar
        focusAddressBar = { [weak bar] in bar?.beginEditing() }
        bar.onEndEditing = { [weak self] in self?.focus(.content) }
        bar.onCycleFocus = { [weak self] forward in self?.focus(FocusCycle.next(after: .addressBar, forward: forward)) }
        scenarioHooks.addressText = { [weak bar] in bar?.displayText ?? "" }
        scenarioHooks.isEditingAddress = { [weak bar] in bar?.isEditing ?? false }
    }

    /// The search field and the content's scope bar share the window's SearchController (P3-10).
    private func installSearch() {
        let content = contentPane as? ContentViewController
        content?.searchController = searchController
        let field = toolbarController.search
        field.onEndEditing = { [weak self] in self?.focus(.content) }
        field.onFocusChange = { [weak content] focused in content?.searchFieldFocused = focused }
    }

    /// The content split item's controller (ContentViewController).
    var contentPane: CommandHandlingViewController? {
        splitViewController.splitViewItems.last?.viewController as? CommandHandlingViewController
    }

    /// The sidebar split item's controller (P1-26 placeholder, P1-28 SidebarViewController).
    var sidebarPane: CommandHandlingViewController? {
        splitViewController.splitViewItems.first?.viewController as? CommandHandlingViewController
    }

    /// Tab cycle, ⌘L, ⌘F (§5.6).
    func focus(_ target: FocusContext) {
        switch target {
        case .addressBar:
            focusAddressBar?()
        case .content, .searchResults:
            makeFirstResponder(in: contentPane)
        case .sidebarFavorites, .sidebarSavedSearch, .sidebarLocations, .sidebarFolders, .sidebarVolumeRoot:
            makeFirstResponder(in: sidebarPane)
        case .fieldEditor:
            break
        }
    }

    /// Commands from the menu bar (or a key equivalent) reach the content pane when the first responder is outside both
    /// panes (the window itself, a toolbar control). Field editors and the panes precede this in the responder chain,
    /// so they still handle (and validate) their commands first.
    public override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        if MenuValidation.command(for: action) != nil, let pane = contentPane, pane.responds(to: action) { return pane }
        return super.supplementalTarget(forAction: action, sender: sender)
    }

    private func makeFirstResponder(in pane: NSViewController?) {
        guard let window, let view = pane?.view, let responder = Self.firstAcceptingView(in: view) else { return }
        window.makeFirstResponder(responder)
    }

    /// Depth-first: the first view that takes keyboard focus (the table in Details, the grid in Icons). Hidden
    /// subtrees (the collapsed search scope bar) and the scope bar's controls never take it: content focus is the list.
    private static func firstAcceptingView(in view: NSView) -> NSView? {
        if view.isHidden || view is SearchScopeBar { return nil }
        if view.acceptsFirstResponder { return view }
        for subview in view.subviews {
            if let found = firstAcceptingView(in: subview) { return found }
        }
        return nil
    }

    // MARK: session

    private func handle(_ event: SessionEvent) {
        switch event {
        case .folderChanged:
            if session.results == nil { quickLook.bind(session.folder) }
            folderDidChange()
        case .resultsChanged(let results):
            quickLook.bind(results ?? session.folder)
            updateTitle()
        case .historyChanged, .viewModeChanged, .viewStateChanged, .banner, .columnsChanged, .searchTextChanged, .searchChanged: break
        }
    }

    private func folderDidChange() {
        updateTitle()
        context.environment.settings.lastLocation = session.folder.directory
        window?.invalidateRestorableState()
    }

    private func updateTitle() {
        if let results = session.results {          // "Search Results in “X”", like the address bar (P3-10)
            let title = ToolbarController.resultsTitle(results, folder: session.folder.directory)
            window?.title = title
            window?.tab.title = title
            window?.tab.toolTip = results.spec.map { BreadcrumbPath.posixPath($0.root) }
            return
        }
        let folder = session.folder
        let volume = context.environment.volumes.volume(for: folder.directory)
        let isVolumeRoot = volume.map { Self.samePath($0.mountPoint, folder.directory) } ?? false
        window?.title = WindowTitle.title(for: folder.directory, volumeName: isVolumeRoot ? volume?.name : nil,
                                          fullPath: context.environment.settings.showFullPathInTitle)
        // The tab always shows the folder's name; the full path is its tooltip (P2-05).
        window?.tab.title = TabController.tabTitle(for: folder.directory, volumes: context.environment.volumes)
        window?.tab.toolTip = TabController.tabToolTip(for: folder.directory)
    }

    private static func samePath(_ a: URL, _ b: URL) -> Bool {
        func key(_ url: URL) -> String {
            var p = url.standardizedFileURL.path(percentEncoded: false)
            while p.count > 1, p.hasSuffix("/") { p.removeLast() }
            return p
        }
        return key(a) == key(b)
    }

    // MARK: NSWindowDelegate

    /// Field editor → a per-edit manager (typing undo stays inside the edit); otherwise the app-wide stack (§6.6).
    public func windowDidBecomeKey(_ notification: Notification) {
        quickLookWindowDidBecomeKey()
    }

    public func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        guard let editor = window.firstResponder as? NSText, editor.isFieldEditor else {
            fieldEditorUndo = nil
            return context.environment.undo.undoManager
        }
        let owner = ObjectIdentifier(editor.delegate.map { $0 as AnyObject } ?? editor)
        if let current = fieldEditorUndo, current.owner == owner { return current.manager }
        let manager = context.environment.undo.makeFieldEditorUndoManager()
        fieldEditorUndo = (owner, manager)
        return manager
    }

    public func window(_ window: NSWindow, willEncodeRestorableState state: NSCoder) {
        BrowserWindowRestoration.encode(session.folder.directory, into: state)
    }

    public func windowWillClose(_ notification: Notification) {
        quickLook.bind(nil)
        searchController.cancelPending()
        sessionToken = nil
        titleLoop?.cancel()
        titleLoop = nil
        (sidebarPane as? SidebarViewController)?.close()
        session.close()
        onClose?()
        onClose = nil
    }
}
