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
    var scenarioHooks = ScenarioHooks()
    /// Installed by the address bar (P1-27): ⌘L / ⌥D / F4 begin editing it.
    var focusAddressBar: (() -> Void)?
    /// WindowManager drops the window from its list.
    var onClose: (() -> Void)?

    private var sessionToken: ObserverToken?
    private var fieldEditorUndo: (owner: ObjectIdentifier, manager: UndoManager)?

    init(context: UIContext, initialURL: URL) {
        self.context = context
        self.session = BrowserSession(environment: context.environment, initialURL: initialURL)
        self.splitViewController = BrowserSplitViewController(context: context, session: session)
        self.toolbarController = ToolbarController(context: context, session: session)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.isReleasedWhenClosed = false
        window.identifier = BrowserWindowRestoration.identifier
        window.setAccessibilityIdentifier(AXID.window)
        window.minSize = NSSize(width: 520, height: 320)
        window.tabbingMode = .disallowed
        let toolbar = NSToolbar(identifier: "macx.browser.toolbar")
        toolbar.displayMode = .iconOnly
        if !context.options.isSandboxed { toolbar.autosavesConfiguration = true }
        toolbar.delegate = toolbarController
        toolbar.allowsUserCustomization = true
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden     // the address bar shows where we are; the title still names the window
        window.isRestorable = !context.options.isSandboxed
        window.restorationClass = BrowserWindowRestoration.self
        window.delegate = self
        window.contentViewController = splitViewController
        window.setContentSize(NSSize(width: 1000, height: 640))

        // Interim handler (P1-26): navigation and window commands. P1-35 installs FileCommandController instead.
        let shell = ShellCommandHandler(context: context, window: self)
        contentPane?.handler = shell
        sidebarPane?.handler = shell

        installToolbarHooks()
        sessionToken = session.observe { [weak self] event in self?.handle(event) }
        folderDidChange()
    }

    required init?(coder: NSCoder) { fatalError("BrowserWindowController is created in code") }

    /// The window number (stable while the window exists); job origins and sheet hosts use it.
    public var origin: OriginID { OriginID(raw: window?.windowNumber ?? 0) }

    public func navigate(to url: URL, selecting name: String? = nil) {
        session.navigate(to: url, selecting: name)
    }

    /// The toolbar's address bar (Phase 4 tests submit through it).
    var addressBar: AddressBarView { toolbarController.addressBar }

    /// ⌘L / ⌥D / F4 edit the address; Return/Esc hand the keyboard back to the content; scenario address hooks.
    private func installToolbarHooks() {
        let bar = toolbarController.addressBar
        focusAddressBar = { [weak bar] in bar?.beginEditing() }
        bar.onEndEditing = { [weak self] in self?.focus(.content) }
        scenarioHooks.addressText = { [weak bar] in bar?.displayText ?? "" }
        scenarioHooks.isEditingAddress = { [weak bar] in bar?.isEditing ?? false }
    }

    /// The content split item's controller (P1-26 placeholder, P1-31 ContentViewController).
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
        case .content:
            makeFirstResponder(in: contentPane)
        case .sidebarFavorites, .sidebarLocations, .sidebarFolders, .sidebarVolumeRoot:
            makeFirstResponder(in: sidebarPane)
        case .fieldEditor:
            break
        }
    }

    private func makeFirstResponder(in pane: NSViewController?) {
        guard let window, let view = pane?.view, let responder = Self.firstAcceptingView(in: view) else { return }
        window.makeFirstResponder(responder)
    }

    /// Depth-first: the first view that takes keyboard focus (the table in Details, the grid in Icons).
    private static func firstAcceptingView(in view: NSView) -> NSView? {
        if view.acceptsFirstResponder, !view.isHidden { return view }
        for subview in view.subviews {
            if let found = firstAcceptingView(in: subview) { return found }
        }
        return nil
    }

    // MARK: session

    private func handle(_ event: SessionEvent) {
        switch event {
        case .folderChanged: folderDidChange()
        case .historyChanged, .viewModeChanged, .banner: break
        }
    }

    private func folderDidChange() {
        let folder = session.folder
        let volume = context.environment.volumes.volume(for: folder.directory)
        let isVolumeRoot = volume.map { Self.samePath($0.mountPoint, folder.directory) } ?? false
        window?.title = WindowTitle.title(for: folder.directory, volumeName: isVolumeRoot ? volume?.name : nil,
                                          fullPath: context.environment.settings.showFullPathInTitle)
        context.environment.settings.lastLocation = folder.directory
        window?.invalidateRestorableState()
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
        sessionToken = nil
        (sidebarPane as? SidebarViewController)?.close()
        session.close()
        onClose?()
        onClose = nil
    }
}
