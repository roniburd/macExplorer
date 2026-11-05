import Foundation
import Core
import MacxFS

enum SessionEvent {
    case folderChanged(FolderModel), historyChanged, viewModeChanged(ViewMode), banner(String?)
    /// The folder's view state (P2-08): after every navigation, user change, identity correction and reload.
    case viewStateChanged(FolderViewState)
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

    init(environment: CoreEnvironment, initialURL: URL) {
        self.environment = environment
        let viewStates = FolderViewCoordinator(store: environment.folderViews, settings: environment.settings,
                                               lanes: environment.lanes, volumes: environment.volumes)
        self.viewStates = viewStates
        let (state, locator) = viewStates.state(for: initialURL, fileID: nil)
        self.viewState = state
        self.locator = locator
        self.viewMode = state.mode
        self.folder = environment.makeFolderModel(initialURL, query: Self.query(for: state, settings: environment.settings))
        self.history = NavigationHistory(current: initialURL)
        folder.setGrouping(Self.grouping(for: state))
        attach(folder)
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

    /// Opens the parent and selects the folder we came from (Explorer). Nothing above "/".
    func goUp() {
        let path = folder.directory.standardizedFileURL.path(percentEncoded: false)
        guard path != "/", !path.isEmpty else { return }
        let child = folder.directory.lastPathComponent
        navigate(to: folder.directory.deletingLastPathComponent(), selecting: child)
    }

    /// F5/⌘R: re-read + diff of the same model (retry from an error state).
    func reload() {
        folder.refresh()
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
        viewStates.save(next, for: locator)
        apply(next)
    }

    /// Re-reads this folder's state (after "Apply to All Folders" in another window or tab).
    func reloadViewState() {
        guard !closed else { return }
        apply(viewStates.state(for: locator))
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
        folder.close()
    }

    /// Selects `name` as soon as it is listed (first window opened "selecting:" a name).
    func selectWhenListed(_ name: String) {
        pendingSelection = name
        applyPendingSelection()
    }

    // MARK: private

    private func open(_ url: URL, selecting name: String?, folderID: UInt64? = nil) {
        folderToken = nil
        folder.close()
        let (state, locator) = viewStates.state(for: url, fileID: folderID)
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
        let model = folder
        let viewStates = self.viewStates
        refineTask = Task { [weak self] in
            let refined = await viewStates.refine(start)
            guard let self, !Task.isCancelled, !self.closed, self.folder === model, self.locator == start,
                  refined != start else { return }
            self.locator = refined
            if self.editedSinceNavigation {
                viewStates.save(self.viewState, for: refined)
                return
            }
            let better = viewStates.state(for: refined)
            if better != self.viewState {
                self.apply(better)
            } else if refined.objectKey != nil, viewStates.hasOverride(for: refined) {
                viewStates.save(better, for: refined)      // a path record becomes an object record
            }
        }
    }

    private func apply(_ state: FolderViewState) {
        let old = viewState
        viewState = state
        if state.sort != old.sort {
            var query = folder.query
            query.sort = state.sort
            folder.setQuery(query)
        }
        setDisplayedMode(state.mode)
        folder.setGrouping(Self.grouping(for: state))
        if state != old { observers.send(.viewStateChanged(state)) }
    }

    /// The only writer of `viewMode`. Until P2-19 `.columns` is shown as Details by ContentViewController.
    private func setDisplayedMode(_ mode: ViewMode) {
        guard mode != viewMode else { return }
        viewMode = mode
        observers.send(.viewModeChanged(mode))
    }

    private func attach(_ model: FolderModel) {
        folderToken = model.observe { [weak self, weak model] event in
            guard let self, let model, model === self.folder else { return }
            self.handle(event)
        }
        model.start()
        applyPendingSelection()
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
        case .beginRename, .query, .groups, .folderSizes:
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
        guard folder.query.showHidden != wanted else { return }
        var query = folder.query
        query.showHidden = wanted
        folder.setQuery(query)
    }

    private func showBanner(_ text: String?) {
        guard text != bannerText else { return }
        bannerText = text
        observers.send(.banner(text))
    }
}
