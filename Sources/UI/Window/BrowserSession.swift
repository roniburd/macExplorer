import Foundation
import Core
import MacxFS

enum SessionEvent {
    case folderChanged(FolderModel), historyChanged, viewModeChanged(ViewMode), banner(String?)
    /// The folder's view state (P2-08): after every navigation, user change, identity correction and reload.
    case viewStateChanged(FolderViewState)
    /// The Columns view's chain changed (P2-18): columns opened or closed, or the active column moved.
    case columnsChanged
}

/// Per-window navigation (§5.2): the current FolderModel, back/forward history and view mode. Navigating closes
/// the previous model first, so its late batches, stalls and completions never reach the new folder (Review Focus 3).
/// Every folder has its own view state (P2-08): it is looked up in memory on navigation (the first paint never
/// waits for I/O), refined by the folder's fileID when that was not known, and every user change is saved for the
/// current folder only through `updateViewState`.
@MainActor
final class BrowserSession {
    private let environment: CoreEnvironment
    private(set) var folder: FolderModel
    private(set) var history: NavigationHistory
    /// The displayed mode: `viewState.mode`, set only through `setDisplayedMode`.
    private(set) var viewMode: ViewMode
    /// The current folder's view state (its own record or the defaults).
    private(set) var viewState: FolderViewState
    /// Where the current folder's state is saved; gains the fileID once the identity probe returns.
    private(set) var locator: FolderViewLocator
    private let viewStates: FolderViewCoordinator
    /// The user changed the view state since the last navigation (the identity probe must not overwrite it).
    private var editedSinceNavigation = false
    private var refineTask: Task<Void, Never>?

    private let observers = Observers<SessionEvent>()
    private var folderToken: ObserverToken?
    /// A name to select once it is listed (goUp, address-bar file, "selecting:"). Dropped when the first full
    /// listing completes without it and on any other selection change, so it never fires later (QA round 1).
    private var pendingSelection: String?
    private var settingsLoop: ObservationLoop?
    private var bannerText: String?
    private var closed = false
    /// Folder sizes (P2-14): while the folder's "Calculate Folder Sizes" is on and the window shows Details, one
    /// session sizes the current model's folders. Stopped on navigation, a mode change away and the toggle off.
    private(set) var sizeSession: FolderSizeSession?
    /// Columns mode (P2-18): the chain owns every column's model, and `folder` is the active column's (borrowed:
    /// the session never closes it itself). The view state belongs to the column root. nil in other modes.
    private(set) var columnChain: ColumnChain?
    /// The session itself is rerooting the chain (navigation): its own bookkeeping runs, not `chainRerooted`.
    private var rerootingChain = false
    /// The column root came from the chain's own reroot (⌘↑ at the root) and its stored mode is not Columns: the
    /// window shows it in Columns from memory only. Nothing is saved until the user changes the view state (review
    /// fix: ⌘↑ must not rewrite the parent's own mode). Cleared on navigation and when leaving Columns.
    private var columnsShownWithoutRecord = false

    init(environment: CoreEnvironment, initialURL: URL) {
        self.environment = environment
        let viewStates = FolderViewCoordinator(store: environment.folderViews, settings: environment.settings,
                                               lanes: environment.lanes, volumes: environment.volumes)
        self.viewStates = viewStates
        let (state, locator) = viewStates.state(for: initialURL, fileID: nil)
        self.viewState = state
        self.locator = locator
        self.viewMode = state.mode == .columns ? .details : state.mode   // Columns adopts the model below
        self.folder = environment.makeFolderModel(initialURL, query: Self.query(for: state, settings: environment.settings))
        self.history = NavigationHistory(current: initialURL)
        folder.setGrouping(Self.grouping(for: state))
        attach(folder)
        if state.mode == .columns { setDisplayedMode(.columns) }
        updateFolderSizes()
        refineLocator()
        // Every window follows Settings.showHidden (⇧⌘. or the Settings window in any window, QA round 1).
        settingsLoop = ObservationLoop({ [weak self] in _ = self?.environment.settings.showHidden },
                                       onChange: { [weak self] in self?.applyShowHiddenSetting() })
    }

    /// Closes the previous model, opens `url`, and (optionally) records it in history. `folderID` is the folder's
    /// fileID when the caller has it from the same `stat` probe (`FolderIdentityProbe`); otherwise a lane probe adds
    /// it later. Never pass a listing's `Entry.fileID`: for a mount point it is the covered folder's (review fix).
    func navigate(to url: URL, selecting name: String? = nil, recordHistory: Bool = true, folderID: UInt64? = nil) {
        guard !closed else { return }
        showBanner(nil)
        open(url, selecting: name, folderID: folderID)
        if recordHistory {
            history.visit(url)
            observers.send(.historyChanged)
        }
    }

    func goBack() {
        guard !closed, let url = history.goBack() else { return }
        showBanner(nil)
        open(url, selecting: nil)
        observers.send(.historyChanged)
    }

    func goForward() {
        guard !closed, let url = history.goForward() else { return }
        showBanner(nil)
        open(url, selecting: nil)
        observers.send(.historyChanged)
    }

    /// Back-history menu: `index` into `history.backList` (0 = oldest).
    func goBack(toIndex index: Int) {
        guard !closed, let url = history.jump(toBackIndex: index) else { return }
        showBanner(nil)
        open(url, selecting: nil)
        observers.send(.historyChanged)
    }

    /// Forward-history menu: `index` into `history.forwardList` (0 = next).
    func goForward(toIndex index: Int) {
        guard !closed, let url = history.jump(toForwardIndex: index) else { return }
        showBanner(nil)
        open(url, selecting: nil)
        observers.send(.historyChanged)
    }

    /// Opens the parent and selects the folder we came from (Explorer). Nothing above "/". In Columns (P2-19) it is
    /// the chain's up: the parent column, or at the column root a new root for the parent (recorded in history).
    func goUp() {
        if let chain = columnChain { chain.up(); return }
        let path = folder.directory.standardizedFileURL.path(percentEncoded: false)
        guard path != "/", !path.isEmpty else { return }
        let child = folder.directory.lastPathComponent
        navigate(to: folder.directory.deletingLastPathComponent(), selecting: child)
    }

    /// F5/⌘R: re-read + diff of the same model (retry from an error state).
    func reload() {
        folder.refresh()
        sizeSession?.retry()
    }

    func observe(_ handler: @escaping @MainActor (SessionEvent) -> Void) -> ObserverToken { observers.add(handler) }

    // MARK: view state (P2-08)

    /// Every user change of mode, columns, sort, icon size (and later Group by, folder sizes): saved for this folder
    /// only, then applied. The global defaults (`Settings.viewMode/sort/iconSize/columns`) are never written here.
    func updateViewState(_ mutate: (inout FolderViewState) -> Void) {
        guard !closed else { return }
        var next = viewState
        mutate(&next)
        guard next != viewState else { return }
        editedSinceNavigation = true
        if columnChain != nil, next.mode != .columns {
            leaveColumns(with: next)
            return
        }
        viewStates.save(next, for: locator)
        columnsShownWithoutRecord = false               // the user's change saved Columns with it
        apply(next)
    }

    /// Re-reads this folder's state (after "Apply to All Folders" in another window or tab).
    func reloadViewState() {
        guard !closed else { return }
        let state = shown(viewStates.state(for: locator))
        if columnChain != nil, state.mode != .columns { leaveColumns(with: state); return }
        apply(state)
    }

    /// The window closed: the model stops reading and watching.
    func close() {
        guard !closed else { return }
        closed = true
        refineTask?.cancel()
        refineTask = nil
        settingsLoop?.cancel()
        settingsLoop = nil
        folderToken = nil
        stopFolderSizes()
        closeFolderOrChain()
    }

    /// Selects `name` as soon as it is listed (first window opened "selecting:" a name).
    func selectWhenListed(_ name: String) {
        pendingSelection = name
        applyPendingSelection()
    }

    // MARK: private

    private func open(_ url: URL, selecting name: String?, folderID: UInt64? = nil) {
        columnsShownWithoutRecord = false
        folderToken = nil
        stopFolderSizes()
        let (state, locator) = viewStates.state(for: url, fileID: folderID)
        if let chain = columnChain, state.mode == .columns {
            // Columns stay: the chain gets a new root column (the factory reads the new root's sort).
            viewState = state
            self.locator = locator
            editedSinceNavigation = false
            pendingSelection = nil
            rerootingChain = true
            chain.reroot(url, selecting: name)    // onChange: `folder` becomes the new root column
            rerootingChain = false
            observers.send(.viewStateChanged(state))
            refineLocator()
            return
        }
        closeFolderOrChain()
        viewState = state
        self.locator = locator
        editedSinceNavigation = false
        let model = environment.makeFolderModel(url, query: Self.query(for: state, settings: environment.settings))
        model.setGrouping(Self.grouping(for: state))     // before start: the first listing is already grouped
        folder = model
        pendingSelection = name
        attach(model)
        observers.send(.folderChanged(model))
        setDisplayedMode(state.mode)
        updateFolderSizes()
        observers.send(.viewStateChanged(state))
        refineLocator()
    }

    private static func query(for state: FolderViewState, settings: Settings) -> ViewQuery {
        ViewQuery(sort: state.sort, showHidden: settings.showHidden)
    }

    /// Group by applies only while the window displays Details (P2-09); Icons and Columns are never grouped.
    static func grouping(for state: FolderViewState) -> GroupBy {
        state.mode == .details ? state.groupBy : .none
    }

    /// Identity correction: without a fileID on an idStable volume, probe it on a lane. If the folder is still
    /// current, keep the refined locator; its own record (found by object key after a rename or move) wins over
    /// the path lookup, unless the user changed the view meanwhile, in which case that change is saved under it.
    private func refineLocator() {
        refineTask?.cancel()
        let start = locator
        guard start.fileID == nil, start.volume?.capabilities.idStable == true else { refineTask = nil; return }
        let model = stateModel
        let viewStates = self.viewStates
        refineTask = Task { [weak self] in
            let refined = await viewStates.refine(start)
            guard let self, !Task.isCancelled, !self.closed, self.stateModel === model, self.locator == start,
                  refined != start else { return }
            self.locator = refined
            if self.editedSinceNavigation {
                viewStates.save(self.viewState, for: refined)
                return
            }
            let stored = viewStates.state(for: refined)
            let better = self.shown(stored)
            if better != self.viewState {
                self.apply(better)
            } else if refined.objectKey != nil, viewStates.hasOverride(for: refined) {
                viewStates.save(stored, for: refined)      // a path record becomes an object record
            }
        }
    }

    /// `state` as the window shows it: Columns while the column root is shown without a Columns record.
    private func shown(_ state: FolderViewState) -> FolderViewState {
        guard columnsShownWithoutRecord, columnChain != nil else { return state }
        var shown = state
        shown.mode = .columns
        return shown
    }

    private func apply(_ state: FolderViewState) {
        let old = viewState
        viewState = state
        // Every column uses the root's sort; after leaving Columns the kept model may still have the root's.
        for model in displayedModels where model.query.sort != state.sort {
            var query = model.query
            query.sort = state.sort
            model.setQuery(query)
        }
        setDisplayedMode(state.mode)
        folder.setGrouping(Self.grouping(for: state))
        updateFolderSizes()
        if state != old { observers.send(.viewStateChanged(state)) }
    }

    /// Folder sizes follow the view state and the displayed mode (Details only): enabled on the model, with one
    /// session while on; off stops the session and clears the sizes.
    private func updateFolderSizes() {
        let on = viewState.calculateFolderSizes && viewMode == .details
        if on {
            folder.setFolderSizesEnabled(true)
            if sizeSession == nil { sizeSession = environment.folderSizes.attach(to: folder) }
        } else {
            stopFolderSizes()
            folder.setFolderSizesEnabled(false)
        }
    }

    private func stopFolderSizes() {
        sizeSession?.stop()
        sizeSession = nil
    }

    /// The only writer of `viewMode`. Entering Columns adopts the current model as column 0 (nothing is re-read);
    /// leaving Columns is `leaveColumns`, which retargets the view state first. ContentViewController shows the
    /// chain in its ColumnsViewController (P2-19).
    private func setDisplayedMode(_ mode: ViewMode) {
        guard mode != viewMode else { return }
        if mode == .columns, columnChain == nil {
            let chain = ColumnChain(adopting: folder) { [unowned self] url in
                self.environment.makeFolderModel(url, query: Self.query(for: self.viewState, settings: self.environment.settings))
            }
            columnChain = chain
            chainRoot = chain.models.first
            chain.onChange = { [weak self] in self?.columnChainChanged() }
            viewMode = mode
            observers.send(.viewModeChanged(mode))
            columnChainChanged()            // the adopted folder may already have opened column 1
            return
        }
        if viewMode == .columns, let chain = columnChain {
            chain.onChange = nil
            folder = chain.detachActive()
            columnChain = nil
            chainRoot = nil
            observeFolder(folder)
            observers.send(.folderChanged(folder))
        }
        viewMode = mode
        observers.send(.viewModeChanged(mode))
    }

    /// Switching from Columns to another mode (Finder): the state is retargeted to the active column's folder,
    /// that folder is shown in `requested.mode`, and that mode is saved for it. The column root keeps its own record
    /// (still Columns). When the root column is active, `requested` is saved for it as it is.
    private func leaveColumns(with requested: FolderViewState) {
        guard let chain = columnChain else { return }
        columnsShownWithoutRecord = false
        refineTask?.cancel()
        refineTask = nil
        var next = requested
        if chain.activeModel !== chain.models.first {
            let (state, locator) = viewStates.state(for: chain.activeModel.directory, fileID: nil)
            viewState = state
            self.locator = locator
            next = state
            next.mode = requested.mode
        }
        let retargeted = chain.activeModel !== chain.models.first
        setDisplayedMode(next.mode)         // detaches the active model; the chain closes the others
        viewStates.save(next, for: locator)
        apply(next)
        if retargeted {                     // the window now shows a deeper folder: Back returns to the column root
            history.visit(folder.directory)
            observers.send(.historyChanged)
        }
        refineLocator()
    }

    /// The chain opened or closed columns, or the active column moved: `folder` follows the active column.
    /// The search filter follows the active column (plan P2-18): the column that loses activation is unfiltered.
    private func columnChainChanged() {
        guard let chain = columnChain, !chain.models.isEmpty else { return }
        if !rerootingChain, let root = chain.models.first, root !== chainRoot {
            chainRerooted(root)
        }
        chainRoot = chain.models.first
        if chain.activeModel !== folder {
            let previous = folder
            if !previous.query.filter.isEmpty, chain.models.contains(where: { $0 === previous }) {
                var query = previous.query
                query.filter = ""
                previous.setQuery(query)
            }
            folder = chain.activeModel      // borrowed: the chain owns and closes it
            observeFolder(folder)
            observers.send(.folderChanged(folder))
        }
        observers.send(.columnsChanged)
    }

    /// The chain rerooted itself (⌘↑ at the root column): the view state follows the new root and the move is
    /// recorded in history. The window stays in Columns; when the new root's own mode is not Columns, that is kept
    /// in memory only (`columnsShownWithoutRecord`), so the identity probe and reloads keep Columns while the
    /// folder's stored mode is untouched (explicit navigation to it still opens its own mode).
    private func chainRerooted(_ root: FolderModel) {
        let (state, locator) = viewStates.state(for: root.directory, fileID: nil)
        var shown = state
        shown.mode = .columns
        let old = viewState
        viewState = shown
        self.locator = locator
        editedSinceNavigation = false
        columnsShownWithoutRecord = state.mode != .columns
        if shown.sort != old.sort {
            for model in displayedModels where model.query.sort != shown.sort {
                var query = model.query
                query.sort = shown.sort
                model.setQuery(query)
            }
        }
        history.visit(root.directory)
        observers.send(.historyChanged)
        if shown != old { observers.send(.viewStateChanged(shown)) }
        refineLocator()
    }

    /// The column root identity seen by the last `columnChainChanged` (detects the chain's own reroots).
    private var chainRoot: FolderModel?

    /// The model whose folder the view state belongs to: the column root in Columns, otherwise `folder`.
    private var stateModel: FolderModel { columnChain?.models.first ?? folder }

    /// Every model the window shows: all columns in Columns, otherwise `folder`.
    private var displayedModels: [FolderModel] { columnChain?.models ?? [folder] }

    /// Leaves nothing reading: the chain closes all its columns (including `folder`), otherwise `folder` closes.
    private func closeFolderOrChain() {
        if let chain = columnChain {
            chain.onChange = nil
            chain.close()
            columnChain = nil
            chainRoot = nil
        }
        folder.close()                      // idempotent when the chain already closed it
    }

    private func attach(_ model: FolderModel) {
        observeFolder(model)
        model.start()
        applyPendingSelection()
    }

    /// Routes `model`'s events to `handle` while it is `folder`.
    private func observeFolder(_ model: FolderModel) {
        folderToken = model.observe { [weak self, weak model] event in
            guard let self, let model, model === self.folder else { return }
            self.handle(event)
        }
    }

    private func handle(_ event: FolderEvent) {
        switch event {
        case .relocate(let url, let reason):
            navigate(to: url)
            switch reason {
            case .movedOrDeleted(let name): showBanner(String(format: L10n.string("'%@' was moved or deleted"), name))
            case .volumeGone: showBanner(L10n.string("The volume was disconnected"))
            }
        case .state(.error(.notFound)), .state(.error(.volumeGone)):
            applyPendingSelection()
            folder.relocateIfGone()
        case .changes, .state:
            applyPendingSelection()
        case .selection:
            pendingSelection = nil          // the user (or a file operation) chose a selection meanwhile
        case .beginRename, .query, .groups, .folderSizes, .extendedAttributes:
            break
        }
    }

    private func applyPendingSelection() {
        guard let name = pendingSelection else { return }
        guard folder.row(named: name) != nil else {
            // The full listing doesn't show it (hidden, gone): forget it rather than select it out of nowhere later.
            switch folder.state {
            case .complete, .error: pendingSelection = nil
            case .loading, .partial, .unresponsive, .waitingForPermission: break
            }
            return
        }
        pendingSelection = nil
        folder.select(.names([name]))
    }

    private func applyShowHiddenSetting() {
        guard !closed else { return }
        let wanted = environment.settings.showHidden
        for model in displayedModels where model.query.showHidden != wanted {
            var query = model.query
            query.showHidden = wanted
            model.setQuery(query)
        }
    }

    private func showBanner(_ text: String?) {
        guard text != bannerText else { return }
        bannerText = text
        observers.send(.banner(text))
    }
}
