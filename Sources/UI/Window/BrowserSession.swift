import Foundation
import Core
import MacxFS

enum SessionEvent {
    case folderChanged(FolderModel), historyChanged, viewModeChanged(ViewMode), banner(String?)
    /// The folder's view state (P2-08): after every navigation, user change, identity correction and reload.
    case viewStateChanged(FolderViewState)
    /// The Columns view's chain changed (P2-18): columns opened or closed, or the active column moved.
    case columnsChanged
    /// The window shows these search results instead of the folder, or (nil) the folder again (P3-10).
    case resultsChanged(SearchResultsModel?)
    /// The search the window shows changed from outside the field (history, navigation clearing it, saved search):
    /// the field shows this text and adopts `searchSpec`.
    case searchTextChanged(String)
    /// `searchSpec` or `lastPlan` changed (a search was planned or cleared): the scope bar refreshes its notices.
    case searchChanged
}

/// Per-window navigation (§5.2): the current FolderModel, back/forward history and view mode. Navigating closes
/// the previous model first, so its late batches, stalls and completions never reach the new folder (Review Focus 3).
/// Every folder has its own view state (P2-08, design 2026-11-05 §2): it is resolved in memory on navigation (the
/// first paint never waits for I/O) from the folder's own record, Finder's `.DS_Store` view if already read, the
/// built-in rule and the defaults; refined by the folder's fileID when that was not known and by Finder's view when
/// it arrives (read on a lane, applied only within `finderApplyDeadline` and before any user change); and every user
/// change is saved for the current folder only (just the changed fields) through `updateViewState`.
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
    /// Finder's `.DS_Store` view of the current folder, read on a lane after opening it.
    private var finderTask: Task<Void, Never>?
    /// Finder data later than this after opening is cached for next time but not applied (no surprise switches).
    static let finderApplyDeadline: Duration = .seconds(1)
    /// Folders follow changes of the global defaults (Settings window, Use as Default) for fields they don't set.
    private var defaultsLoop: ObservationLoop?

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
    /// window shows it in Columns from memory only. The user's later changes (sort, icon size…) are saved with the
    /// stored mode, never Columns (review fix: ⌘↑ must not rewrite the parent's own mode). Cleared on navigation and
    /// when leaving Columns (the user picks another mode).
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
        lookUpFolder()
        defaultsLoop = ObservationLoop({ [weak self] in _ = self?.environment.settings.defaultFolderViewState() },
                                       onChange: { [weak self] in self?.reloadViewState() })
        // Every window follows Settings.showHidden (⇧⌘. or the Settings window in any window, QA round 1) and
        // Settings.showAllExtensions (design 2026-11-05 §1).
        settingsLoop = ObservationLoop({ [weak self] in
            _ = self?.environment.settings.showHidden
            _ = self?.environment.settings.showAllExtensions
        }, onChange: { [weak self] in self?.applyShowHiddenSetting() })
    }

    /// Closes the previous model, opens `url`, and (optionally) records it in history. `folderID` is the folder's
    /// fileID when the caller has it from the same `stat` probe (`FolderIdentityProbe`); otherwise a lane probe adds
    /// it later. Never pass a listing's `Entry.fileID`: for a mount point it is the covered folder's (review fix).
    /// A search URL (`x-macexplorer-search:`, `x-macexplorer-results:`) shows that search (P3-10). Navigating to a
    /// folder while results show parks them under their history URL and clears the search (spec §5.2).
    func navigate(to url: URL, selecting name: String? = nil, recordHistory: Bool = true, folderID: UInt64? = nil) {
        guard !closed else { return }
        showBanner(nil)
        if Self.isSearchURL(url) {
            if recordHistory { history.visit(url) }
            showHistoryEntry(url)
            observers.send(.historyChanged)
            return
        }
        arrive(at: url, selecting: name, folderID: folderID)
        if recordHistory {
            history.visit(url)
            observers.send(.historyChanged)
        }
    }

    func goBack() {
        guard !closed, let url = history.goBack() else { return }
        showBanner(nil)
        arriveFromHistory(at: url)
        observers.send(.historyChanged)
    }

    func goForward() {
        guard !closed, let url = history.goForward() else { return }
        showBanner(nil)
        arriveFromHistory(at: url)
        observers.send(.historyChanged)
    }

    /// Back-history menu: `index` into `history.backList` (0 = oldest).
    func goBack(toIndex index: Int) {
        guard !closed, let url = history.jump(toBackIndex: index) else { return }
        showBanner(nil)
        arriveFromHistory(at: url)
        observers.send(.historyChanged)
    }

    /// Forward-history menu: `index` into `history.forwardList` (0 = next).
    func goForward(toIndex index: Int) {
        guard !closed, let url = history.jump(toForwardIndex: index) else { return }
        showBanner(nil)
        arriveFromHistory(at: url)
        observers.send(.historyChanged)
    }

    /// Back/forward landed on `url` (already `history.current`): a search entry or a folder.
    private func arriveFromHistory(at url: URL) {
        if Self.isSearchURL(url) { showHistoryEntry(url) } else { arrive(at: url, selecting: nil) }
    }

    /// Folder navigation: parks shown results, clears the search, then opens `url` (or, when results were shown over
    /// this same folder, just shows the folder again with `name` selected: nothing is re-read).
    private func arrive(at url: URL, selecting name: String?, folderID: UInt64? = nil) {
        let wasShowingResults = parkResults()
        endSearch()
        if wasShowingResults, Self.samePath(url, folder.directory) {
            if let name { selectWhenListed(name) }
            return
        }
        open(url, selecting: name, folderID: folderID)
    }

    /// Opens the parent and selects the folder we came from (Explorer). Nothing above "/". In Columns (P2-19) it is
    /// the chain's up: the parent column, or at the column root a new root for the parent (recorded in history).
    func goUp() {
        if let root = results?.spec?.root { navigate(to: root); return }    // results: up is the search root
        if let chain = columnChain { chain.up(); return }
        let path = folder.directory.standardizedFileURL.path(percentEncoded: false)
        guard path != "/", !path.isEmpty else { return }
        let child = folder.directory.lastPathComponent
        navigate(to: folder.directory.deletingLastPathComponent(), selecting: child)
    }

    /// F5/⌘R: re-read + diff of the same model (retry from an error state).
    func reload() {
        if let results { results.rerun(); return }                          // results: search again
        folder.refresh()
        sizeSession?.retry()
    }

    func observe(_ handler: @escaping @MainActor (SessionEvent) -> Void) -> ObserverToken { observers.add(handler) }

    // MARK: view state (P2-08)

    /// Every user change of mode, columns, sort, icon size, density, Group by and folder sizes: the changed fields
    /// are saved for this folder only, then applied. The global defaults (`Settings.viewMode/sort/…`) are never
    /// written here.
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
        viewStates.update(next.changes(from: viewState), for: locator)
        apply(next)
    }

    /// Re-resolves this folder's state (after "Apply to All Folders" or "Reset View", a change of the global
    /// defaults, or Finder's view arriving). Saves nothing.
    func reloadViewState() {
        guard !closed else { return }
        let state = shown(viewStates.state(for: locator))
        if columnChain != nil, state.mode != .columns { leaveColumns(with: state, persist: false); return }
        apply(state)
    }

    /// "Use as Default for All Folders": the current view becomes the global default (every window re-resolves).
    func useViewAsDefault() {
        guard !closed else { return }
        viewStates.useAsDefault(viewState)
    }

    /// "Reset View for This Folder": forget MacExplorer's choices here (Finder → built-in → defaults apply again).
    func resetFolderView() {
        guard !closed else { return }
        viewStates.reset(locator)
        editedSinceNavigation = false
        reloadViewState()
    }

    /// The window closed: the model stops reading and watching.
    func close() {
        guard !closed else { return }
        closed = true
        refineTask?.cancel()
        refineTask = nil
        finderTask?.cancel()
        finderTask = nil
        settingsLoop?.cancel()
        settingsLoop = nil
        defaultsLoop?.cancel()
        defaultsLoop = nil
        folderToken = nil
        stopFolderSizes()
        closeFolderOrChain()
        searchToken &+= 1
        results?.close()
        results = nil
        for entry in parked { entry.model.close() }
        parked = []
    }

    /// Selects `name` as soon as it is listed (first window opened "selecting:" a name).
    func selectWhenListed(_ name: String) {
        pendingSelection = name
        applyPendingSelection()
    }

    // MARK: search (P3-10)

    /// History URLs of results that have no spec (Phase 4 TAGS): `x-macexplorer-results:<UUID>`.
    static let resultsScheme = "x-macexplorer-results"
    /// Parked results kept for Back/Forward (least recently shown first evicted).
    static let parkedLimit = 5

    /// The results the window shows instead of the folder; nil while the folder is shown.
    private(set) var results: SearchResultsModel?
    /// The search being shown: a This folder filter (results nil) or the results' spec.
    private(set) var searchSpec: SearchSpec?
    /// The plan of the last `search(_:)` (its notices show in the scope bar for folder filters).
    private(set) var lastPlan: SearchPlan?
    /// The history URL of `results`.
    private var resultsURL: URL?
    /// A newer `search`/`clearSearch` supersedes a plan still being made.
    private var searchToken = 0
    private var parked: [(url: URL, model: SearchResultsModel)] = []     // most recently parked last
    private var externalURLs: [ObjectIdentifier: URL] = [:]

    static func isSearchURL(_ url: URL) -> Bool { url.scheme == SearchSpec.urlScheme || url.scheme == resultsScheme }

    /// Plans `spec` and shows it: an instant folder filter (This folder by name), streaming results (crawler,
    /// Spotlight), the "Spotlight is off" state, or nothing (an empty query clears the search). The first results
    /// shown from a folder add one history entry; a retyped search replaces it and closes the old model.
    func search(_ spec: SearchSpec) async {
        guard !closed else { return }
        searchToken &+= 1
        let token = searchToken
        let plan = await environment.planSearch(spec)
        guard !closed, token == searchToken else { return }
        lastPlan = plan
        switch plan.engine {
        case .none:
            guard plan.notices.contains(.spotlightOff) else { clearSearch(); return }
            let off = SearchResultsModel(title: spec.text.trimmingCharacters(in: .whitespaces), events: { _ in
                AsyncStream { c in c.yield(.notice(.spotlightOff)); c.yield(.completed(SearchSummary())); c.finish() }
            }, context: environment.searchContext())
            clearFolderCriteria()
            searchSpec = spec
            show(off, url: spec.url, spec: spec, recordHistory: results == nil)
        case .folderFilter(let criteria):
            let hadResults = results != nil
            leaveResultsForRoot()
            searchSpec = spec
            var query = folder.query
            query.filter = ""
            query.criteria = criteria
            folder.setQuery(query)
            if hadResults { observers.send(.resultsChanged(nil)) }
            observers.send(.searchChanged)
        case .crawler, .spotlight:
            clearFolderCriteria()
            searchSpec = spec
            show(environment.makeSearchResults(spec, plan: plan), url: spec.url, spec: spec, recordHistory: results == nil)
        }
    }

    /// Shows a model built elsewhere (Phase 4 TAGS, saved searches) and starts it.
    func showResults(_ model: SearchResultsModel, recordHistory: Bool) {
        guard !closed else { return }
        searchToken &+= 1
        clearFolderCriteria()
        searchSpec = model.spec
        lastPlan = model.plan
        show(model, url: model.spec?.url ?? externalURL(for: model), spec: model.spec, recordHistory: recordHistory)
    }

    /// Back to the folder without a new history entry: closes the shown results (the results entry becomes the
    /// search root's), returns to the search root and removes the folder filter.
    func clearSearch() {
        searchToken &+= 1
        guard !closed, results != nil || searchSpec != nil || folder.query.criteria != nil || lastPlan != nil else { return }
        lastPlan = nil
        searchSpec = nil
        clearFolderCriteria()
        let hadResults = results != nil
        leaveResultsForRoot()
        if hadResults { observers.send(.resultsChanged(nil)) }
        observers.send(.searchChanged)
    }

    /// Go › Open Containing Folder (⌥⌘R): the item's folder with the item selected; Back returns to the results.
    func openContainingFolder(of url: URL) {
        var path = url.deletingLastPathComponent().path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        navigate(to: URL(filePath: path), selecting: url.lastPathComponent)
    }

    private func show(_ model: SearchResultsModel, url: URL, spec: SearchSpec?, recordHistory: Bool) {
        if let current = results, current !== model { current.close() }    // replaced, not parked
        parked.removeAll { $0.model === model }
        results = model
        resultsURL = url
        if recordHistory { history.visit(url) } else { history.replaceCurrent(url) }
        if model.generation == .initial { model.start() }
        observers.send(.resultsChanged(model))
        observers.send(.historyChanged)
    }

    /// Results → the search root, replacing the results history entry (no new entry).
    private func leaveResultsForRoot() {
        guard let current = results else { return }
        let root = current.spec?.root ?? folder.directory
        current.close()
        results = nil
        resultsURL = nil
        history.replaceCurrent(root)
        if !Self.samePath(root, folder.directory) { open(root, selecting: nil) }
        observers.send(.historyChanged)
    }

    private func clearFolderCriteria() {
        for model in displayedModels where model.query.criteria != nil || !model.query.filter.isEmpty {
            var query = model.query
            query.criteria = nil
            query.filter = ""
            model.setQuery(query)
        }
    }

    /// Folder navigation ends the search (spec §5.2): the field clears; the folder opened next has no filter.
    private func endSearch() {
        searchToken &+= 1
        lastPlan = nil
        searchSpec = nil
        clearFolderCriteria()
        observers.send(.searchTextChanged(""))
    }

    /// Moves the shown results to the parked list (stopping a running search) so Back/Forward can show them again.
    /// Returns whether results were shown.
    @discardableResult
    private func parkResults() -> Bool {
        guard let current = results else { return false }
        if case .searching = current.state { current.stop() }
        let url = resultsURL ?? current.spec?.url ?? externalURL(for: current)
        parked.removeAll { $0.model === current || $0.url == url }
        parked.append((url, current))
        while parked.count > Self.parkedLimit {
            let evicted = parked.removeFirst().model
            externalURLs[ObjectIdentifier(evicted)] = nil
            evicted.close()
        }
        results = nil
        resultsURL = nil
        observers.send(.resultsChanged(nil))
        return true
    }

    private func externalURL(for model: SearchResultsModel) -> URL {
        if let url = externalURLs[ObjectIdentifier(model)] { return url }
        let url = URL(string: "\(Self.resultsScheme):\(UUID().uuidString)")!
        externalURLs[ObjectIdentifier(model)] = url
        return url
    }

    /// `history.current` is the search or results URL `url`: shows its parked model (same rows, selection and
    /// scroll), or re-runs its spec, or (an external results URL without a parked model) falls back to the folder.
    private func showHistoryEntry(_ url: URL) {
        if resultsURL == url, results != nil { return }
        parkResults()
        if let i = parked.firstIndex(where: { $0.url == url }) {
            let model = parked.remove(at: i).model
            searchToken &+= 1
            clearFolderCriteria()
            results = model
            resultsURL = url
            searchSpec = model.spec
            lastPlan = model.plan
            if let spec = model.spec { observers.send(.searchTextChanged(spec.text)) }
            observers.send(.resultsChanged(model))
            return
        }
        if let spec = SearchSpec(url: url) {
            searchSpec = spec                       // set before the event: the field adopts session.searchSpec
            observers.send(.searchTextChanged(spec.text))
            Task { [weak self] in await self?.search(spec) }
            return
        }
        history.replaceCurrent(folder.directory)
        endSearch()
    }

    private static func samePath(_ a: URL, _ b: URL) -> Bool {
        LexicalPath.standardize(a.path(percentEncoded: false)) == LexicalPath.standardize(b.path(percentEncoded: false))
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
            lookUpFolder()
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
        lookUpFolder()
    }

    private static func query(for state: FolderViewState, settings: Settings) -> ViewQuery {
        ViewQuery(sort: state.sort, showHidden: settings.showHidden, showAllExtensions: settings.showAllExtensions)
    }

    /// Group by applies only while the window displays Details (P2-09); Icons and Columns are never grouped.
    static func grouping(for state: FolderViewState) -> GroupBy {
        state.mode == .details ? state.groupBy : .none
    }

    /// A folder became the current one (navigation, column root change): its identity and Finder's view are looked
    /// up off main.
    private func lookUpFolder() {
        refineLocator()
        readFinderView()
    }

    /// Finder's `.DS_Store` view (design 2026-11-05 §2), read once per launch on a lane for local volumes. Applied
    /// when it arrives while the folder is still current, the user hasn't changed the view since opening it, and
    /// within `finderApplyDeadline`; otherwise only cached for the next visit.
    private func readFinderView() {
        finderTask?.cancel()
        finderTask = nil
        let start = locator
        guard viewStates.needsFinderView(start) else { return }
        let model = stateModel
        let viewStates = self.viewStates
        let started = ContinuousClock.now
        finderTask = Task { [weak self] in
            let found = await viewStates.readFinderView(start)
            guard let self, !Task.isCancelled, !self.closed else { return }
            self.finderTask = nil
            guard self.stateModel === model, self.locator.path == start.path, !self.editedSinceNavigation,
                  let found, !found.isEmpty, ContinuousClock.now - started < Self.finderApplyDeadline else { return }
            self.reloadViewState()
        }
    }

    /// Identity correction: without a fileID on an idStable volume, probe it on a lane. If the folder is still
    /// current, keep the refined locator; a pending path record (an edit made meanwhile) moves to the object key;
    /// the folder's own record (found by object key after a rename or move) wins over the path lookup, unless the
    /// user changed the view meanwhile.
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
            viewStates.adopt(refined)                      // a path record becomes an object record
            if self.editedSinceNavigation { return }
            let better = self.shown(viewStates.state(for: refined))
            if better != self.viewState { self.apply(better) }
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
            chain.onRootRelocate = { [weak self] url, reason in self?.relocate(to: url, reason: reason) }
            viewMode = mode
            observers.send(.viewModeChanged(mode))
            columnChainChanged()            // the adopted folder may already have opened column 1
            return
        }
        if viewMode == .columns, let chain = columnChain {
            chain.onChange = nil
            chain.onRootRelocate = nil
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
    /// that folder is shown in `requested.mode`, and (`persist`, a user change) that mode is saved for it. The column
    /// root keeps its own record (still Columns). When the root column is active, `requested`'s changes are saved
    /// for it. A re-resolve (`persist` false) leaving Columns saves nothing.
    private func leaveColumns(with requested: FolderViewState, persist: Bool = true) {
        guard let chain = columnChain else { return }
        columnsShownWithoutRecord = false
        refineTask?.cancel()
        refineTask = nil
        var next = requested
        var base = viewState
        if chain.activeModel !== chain.models.first {
            let (state, locator) = viewStates.state(for: chain.activeModel.directory, fileID: nil)
            viewState = state
            self.locator = locator
            base = state
            next = state
            next.mode = requested.mode
        }
        let retargeted = chain.activeModel !== chain.models.first
        setDisplayedMode(next.mode)         // detaches the active model; the chain closes the others
        if persist {
            var delta = next.changes(from: base)
            if retargeted { delta.viewMode = next.mode }      // the user picked this mode for the folder shown
            viewStates.update(delta, for: locator)
        }
        apply(next)
        if retargeted {                     // the window now shows a deeper folder: Back returns to the column root
            history.visit(folder.directory)
            observers.send(.historyChanged)
        }
        lookUpFolder()
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
            if !previous.query.filter.isEmpty || previous.query.criteria != nil,
               chain.models.contains(where: { $0 === previous }) {
                var query = previous.query
                query.filter = ""
                query.criteria = nil
                previous.setQuery(query)
                if searchSpec?.scope == .thisFolder { endSearch() }    // the field clears with it
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
        lookUpFolder()
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
            chain.onRootRelocate = nil
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
            relocate(to: url, reason: reason)
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

    /// The shown folder (or the column root, via the chain) is gone: navigate to `url` and say why.
    private func relocate(to url: URL, reason: RelocationReason) {
        if results != nil {
            // The folder under the shown results went away (e.g. a result's folder trashed from the results): swap
            // it quietly; the results, their history entry and the field stay (Review Focus 3).
            open(url, selecting: nil)
            return
        }
        navigate(to: url)
        switch reason {
        case .movedOrDeleted(let name): showBanner(String(format: L10n.string("'%@' was moved or deleted"), name))
        case .volumeGone: showBanner(L10n.string("The volume was disconnected"))
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
        let settings = environment.settings
        for model in displayedModels
        where model.query.showHidden != settings.showHidden || model.query.showAllExtensions != settings.showAllExtensions {
            var query = model.query
            query.showHidden = settings.showHidden
            query.showAllExtensions = settings.showAllExtensions
            model.setQuery(query)
        }
    }

    private func showBanner(_ text: String?) {
        guard text != bannerText else { return }
        bannerText = text
        observers.send(.banner(text))
    }
}
