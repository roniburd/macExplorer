import AppKit
import Core
import MacxFS

/// A plain view that takes keyboard focus, so the placeholder panes sit in the responder chain. `onKeyDown` sees
/// each key first (KeyRouter alternates); unhandled keys go to super.
@MainActor
final class FocusableView: NSView {
    var onKeyDown: ((NSEvent) -> Bool)?
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }
}

/// P1-26 placeholder content with P1-29's command bar and status bar (row count, selection, free space) and the
/// KeyRouter alternates. P1-31 deletes this type: ContentViewController owns the only command and status bars.
@MainActor
final class PlaceholderContentViewController: CommandHandlingViewController {
    let context: UIContext
    let session: BrowserSession
    let commandBar = CommandBarView()
    let statusBar = StatusBarView()
    private var sessionToken: ObserverToken?
    private var folderToken: ObserverToken?
    private var clipboardToken: ObserverToken?
    private var settingsLoop: ObservationLoop?
    private var lastVolumeID: VolumeID?

    init(context: UIContext, session: BrowserSession) {
        self.context = context
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("created in code") }

    override var focusContext: FocusContext { .content }
    override var commandTarget: CommandTarget? { .contentSelection(session.folder) }

    var countText: String { statusBar.countText }
    private var environment: CoreEnvironment { context.environment }

    override func loadView() {
        let root = FocusableView()
        root.onKeyDown = { [weak self, unowned root] event in
            guard let self else { return false }
            return KeyRouter.handle(event, focus: .content, returnKey: self.environment.settings.returnKey, from: root)
        }
        let list = NSView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 0
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        for part in [commandBar, list, statusBar] as [NSView] {
            part.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(part)
            part.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        commandBar.heightAnchor.constraint(equalToConstant: 28).isActive = true
        statusBar.heightAnchor.constraint(equalToConstant: 22).isActive = true
        list.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        root.addSubview(stack)
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
        sessionToken = session.observe { [weak self] event in
            switch event {
            case .folderChanged(let model): self?.bind(model)
            case .historyChanged: self?.updateCommandBar()
            case .viewModeChanged, .banner: break
            }
        }
        clipboardToken = environment.clipboard.observe { [weak self] in self?.updateCommandBar() }
        settingsLoop = ObservationLoop { [weak self] in
            _ = self?.environment.settings.commandBarVisible
        } onChange: { [weak self] in
            self?.applyCommandBarVisibility()
        }
        applyCommandBarVisibility()
        bind(session.folder)
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        updateCommandBar(shiftHeld: event.modifierFlags.contains(.shift))
    }

    private func bind(_ folder: FolderModel) {
        folderToken = folder.observe { [weak self] event in
            switch event {
            case .selection: self?.updateCommandBar(); self?.updateStatus()
            case .changes, .state, .query: self?.updateStatus()
            case .beginRename, .relocate: break
            }
        }
        refreshFreeSpace()
        updateStatus()
        updateCommandBar()
    }

    private func applyCommandBarVisibility() {
        commandBar.isHidden = !environment.settings.commandBarVisible
    }

    private func updateCommandBar(shiftHeld: Bool = NSEvent.modifierFlags.contains(.shift)) {
        let folder = session.folder
        let selected = folder.selection.rows
        let undo = environment.undo
        let state = CommandState(
            selectionCount: folder.selection.count,
            singleFolderSelected: selected.count == 1 && selected.first.map { folder.entry(atRow: $0).kind == .directory } == true,
            canPaste: environment.clipboard.canPaste, canUndo: undo.canUndo, canRedo: undo.canRedo,
            canGoBack: session.history.canGoBack, canGoForward: session.history.canGoForward,
            canGoUp: folder.directory.standardizedFileURL.path != "/")
        commandBar.update(state: state, focus: .content, shiftHeld: shiftHeld)
    }

    private func updateStatus() {
        let folder = session.folder
        let available = lastVolumeID.flatMap { environment.volumes.cachedAvailableCapacity($0) }
        statusBar.update(itemCount: folder.rowCount, selection: folder.selectionSummary, available: available)
    }

    /// Free space (§5.5): fetched on a lane and cached; refreshed when the volume changes.
    private func refreshFreeSpace() {
        guard let volume = session.folder.volume else { return }
        let changed = volume.id != lastVolumeID
        lastVolumeID = volume.id
        guard changed || environment.volumes.cachedAvailableCapacity(volume.id) == nil else { return }
        Task { [weak self] in
            _ = await self?.environment.volumes.refreshAvailableCapacity(volume.id)
            self?.updateStatus()
        }
    }
}
