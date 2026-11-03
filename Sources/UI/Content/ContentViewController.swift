import AppKit
import Core
import MacxFS

/// Content area of a browser window (§5.3–§5.5): command bar, the active list, empty-state overlay and banner
/// (P1-33), status bar. The only observer of the session's current FolderModel.
@MainActor
final class ContentViewController: CommandHandlingViewController {
    let context: UIContext
    let session: BrowserSession
    let details: DetailsViewController
    let commandBar = CommandBarView()
    let statusBar = StatusBarView()
    let stack = NSStackView()
    let listContainer = NSView()
    private(set) var activeList: FileListView
    private var mountedListView: NSView?
    private var folderToken: ObserverToken?
    private var sessionToken: ObserverToken?
    private var volumesToken: ObserverToken?
    private var finishedToken: ObserverToken?
    private var clipboardToken: ObserverToken?
    private var settingsLoop: ObservationLoop?
    private var lastVolumeID: VolumeID?

    init(context: UIContext, session: BrowserSession) {
        self.context = context
        self.session = session
        self.details = DetailsViewController(context: context)
        self.activeList = details
        super.init(nibName: nil, bundle: nil)
        if context.icons.volumeLookup == nil {
            let volumes = context.environment.volumes
            context.icons.volumeLookup = { volumes.volume(for: $0)?.id ?? .unknown }
        }
    }

    required init?(coder: NSCoder) { fatalError("ContentViewController is created in code") }

    override var focusContext: FocusContext { .content }
    override var commandTarget: CommandTarget? { .contentSelection(session.folder) }

    override func loadView() {
        let root = NSView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        for part in [commandBar, listContainer, statusBar] as [NSView] {
            part.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(part)
            part.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        commandBar.heightAnchor.constraint(equalToConstant: 28).isActive = true
        statusBar.heightAnchor.constraint(equalToConstant: 22).isActive = true
        listContainer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        listContainer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .vertical)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(details)
        sessionToken = session.observe { [weak self] event in self?.handle(event) }
        volumesToken = context.environment.volumes.observe { [weak self] _ in self?.refreshFreeSpace(force: true) }
        finishedToken = context.environment.operations.onFinished { [weak self] _, _ in self?.refreshFreeSpace(force: true) }
        clipboardToken = context.environment.clipboard.observe { [weak self] in self?.updateCommandBar() }   // Paste enablement
        settingsLoop = ObservationLoop { [weak self] in
            _ = self?.context.environment.settings.commandBarVisible
        } onChange: { [weak self] in
            self?.applyCommandBarVisibility()
        }
        applyCommandBarVisibility()
        setViewMode(session.viewMode)
        bind(session.folder)
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        updateCommandBar(shiftHeld: event.modifierFlags.contains(.shift))
    }

    // MARK: session and folder events

    private func handle(_ event: SessionEvent) {
        switch event {
        case .folderChanged(let model): bind(model)
        case .viewModeChanged(let mode): setViewMode(mode)
        case .historyChanged: updateCommandBar()
        case .banner: break   // P1-33 shows the banner
        }
    }

    func bind(_ folder: FolderModel) {
        folderToken = folder.observe { [weak self, weak folder] event in
            guard let self, let folder, folder === self.session.folder else { return }
            self.handle(event)
        }
        activeList.bind(folder)
        refreshFreeSpace(force: false)
        updateStatus()
        updateCommandBar()
    }

    func handle(_ event: FolderEvent) {
        switch event {
        case .changes(let changes): activeList.apply(changes); updateStatus()
        case .selection: activeList.reloadSelectionDrawing(); updateStatus(); updateCommandBar()
        case .state: updateStatus()
        case .beginRename(let row): activeList.beginInlineRename(row: row)
        case .relocate: break   // BrowserSession navigates (P1-26)
        case .query: updateStatus()
        }
    }

    // MARK: view mode

    func setViewMode(_ mode: ViewMode) {
        mount(details)   // P1-32 replaces this body to add the Icons view
    }

    func mount(_ list: FileListView) {
        guard mountedListView !== list.view else { return }
        let hadFocus = (view.window?.firstResponder as? NSView)?.isDescendant(of: listContainer) ?? false
        mountedListView?.removeFromSuperview()
        let listView = list.view
        listView.translatesAutoresizingMaskIntoConstraints = false
        listContainer.addSubview(listView, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            listView.topAnchor.constraint(equalTo: listContainer.topAnchor),
            listView.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor),
            listView.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            listView.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
        ])
        mountedListView = listView
        if hadFocus, let focusable = list as? FocusableList { view.window?.makeFirstResponder(focusable.focusView) }
    }

    // MARK: command bar and status bar

    private func applyCommandBarVisibility() {
        commandBar.isHidden = !context.environment.settings.commandBarVisible
    }

    func updateCommandBar(shiftHeld: Bool = NSEvent.modifierFlags.contains(.shift)) {
        let state = CommandStateBuilder.state(for: commandTarget, session: session, environment: context.environment)
        commandBar.update(state: state, focus: .content, shiftHeld: shiftHeld)
    }

    func updateStatus() {
        let folder = session.folder
        let available = lastVolumeID.flatMap { context.environment.volumes.cachedAvailableCapacity($0) }
        statusBar.update(itemCount: folder.rowCount, selection: folder.selectionSummary, available: available)
    }

    /// Free space (§5.5): fetched on a lane, cached; refreshed on navigation to another volume, when an operation
    /// finishes and when volumes change. Navigation within a volume uses the cache.
    private func refreshFreeSpace(force: Bool) {
        guard let volume = session.folder.volume else { updateStatus(); return }
        let changed = volume.id != lastVolumeID
        lastVolumeID = volume.id
        if changed || force || context.environment.volumes.cachedAvailableCapacity(volume.id) == nil {
            Task { [weak self] in
                _ = await self?.context.environment.volumes.refreshAvailableCapacity(volume.id)
                self?.updateStatus()
            }
        }
        updateStatus()
    }
}

extension NSViewController {
    /// Depth-first search of the view-controller tree (split items, children).
    func firstDescendant<T: NSViewController>(of type: T.Type) -> T? {
        if let match = self as? T { return match }
        for child in children {
            if let match = child.firstDescendant(of: type) { return match }
        }
        return nil
    }
}
