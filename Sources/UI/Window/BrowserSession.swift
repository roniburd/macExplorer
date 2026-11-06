import Foundation
import Core
import MacxFS

enum SessionEvent { case folderChanged(FolderModel), historyChanged, viewModeChanged(ViewMode), banner(String?) }

/// Per-window navigation (§5.2): the current FolderModel, back/forward history and view mode. Navigating closes
/// the previous model first, so its late batches, stalls and completions never reach the new folder (Review Focus 3).
@MainActor
final class BrowserSession {
    private let environment: CoreEnvironment
    private(set) var folder: FolderModel
    private(set) var history: NavigationHistory
    /// The current folder's view (design 2026-11-05 §2): lists observe it; user changes persist per folder.
    let view: FolderViewState
    var viewMode: ViewMode {
        get { view.resolved.viewMode }
        set {
            guard newValue != view.resolved.viewMode else { return }
            view.change { $0.viewMode = newValue }
            observers.send(.viewModeChanged(newValue))
        }
    }
    /// Finder's `.DS_Store` view of the current folder, read off main after opening it.
    private var finderTask: Task<Void, Never>?
    /// The user changed the view since the folder opened: late Finder data no longer applies.
    private var userChangedView = false
    private var defaultsLoop: ObservationLoop?
    /// Finder data later than this after opening is cached for next time but not applied (no surprise switches).
    static let finderApplyDeadline: Duration = .seconds(1)

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
        let resolved = Self.resolve(initialURL, environment: environment)
        self.view = FolderViewState(resolved)
        self.folder = environment.makeFolderModel(initialURL, query: Self.query(environment, sort: resolved.sort))
        self.history = NavigationHistory(current: initialURL)
        view.persist = { [weak self] delta in self?.persist(delta) }
        attach(folder)
        readFinderView(initialURL)
        // Folders follow global default changes (Settings window, Use as Default) for fields they don't set.
        defaultsLoop = ObservationLoop({ [weak self] in _ = self?.environment.settings.defaultFolderView },
                                       onChange: { [weak self] in self?.reresolve() })
        // Every window follows Settings.showHidden (⇧⌘. or the Settings window in any window, QA round 1).
        settingsLoop = ObservationLoop({ [weak self] in
            _ = self?.environment.settings.showHidden
            _ = self?.environment.settings.showAllExtensions
        }, onChange: { [weak self] in self?.applyShowHiddenSetting() })
    }

    /// Closes the previous model, opens `url`, and (optionally) records it in history.
    func navigate(to url: URL, selecting name: String? = nil, recordHistory: Bool = true) {
        guard !closed else { return }
        showBanner(nil)
        open(url, selecting: name)
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

    /// The window closed: the model stops reading and watching.
    func close() {
        guard !closed else { return }
        closed = true
        settingsLoop?.cancel()
        settingsLoop = nil
        defaultsLoop?.cancel()
        defaultsLoop = nil
        finderTask?.cancel()
        finderTask = nil
        folderToken = nil
        folder.close()
    }

    /// Selects `name` as soon as it is listed (first window opened "selecting:" a name).
    func selectWhenListed(_ name: String) {
        pendingSelection = name
        applyPendingSelection()
    }

    // MARK: private

    private func open(_ url: URL, selecting name: String?) {
        folderToken = nil
        folder.close()
        finderTask?.cancel()
        userChangedView = false
        let oldMode = view.resolved.viewMode
        let resolved = Self.resolve(url, environment: environment)
        view.replace(resolved)
        let model = environment.makeFolderModel(url, query: Self.query(environment, sort: resolved.sort))
        folder = model
        pendingSelection = name
        attach(model)
        observers.send(.folderChanged(model))
        if resolved.viewMode != oldMode { observers.send(.viewModeChanged(resolved.viewMode)) }
        readFinderView(url)
    }

    // MARK: per-folder view (design 2026-11-05 §2)

    /// "Use as Default for All Folders": the current view becomes the global default.
    func useViewAsDefault() {
        environment.settings.defaultFolderView = view.resolved
    }

    /// "Reset View for This Folder": forget MacExplorer's choices here (Finder → built-in → defaults apply again).
    func resetFolderView() {
        environment.folderViews.remove(folder.directory)
        userChangedView = false
        reresolve()
    }

    static func resolve(_ url: URL, environment: CoreEnvironment) -> ResolvedFolderView {
        let store = environment.folderViews
        return FolderViewResolver.resolve(stored: store.settings(for: url), finder: store.finderView(for: url),
                                          builtIn: FolderViewResolver.builtIn(for: url), defaults: environment.settings.defaultFolderView)
    }

    private static func query(_ environment: CoreEnvironment, sort: MacxFS.SortDescriptor) -> ViewQuery {
        var query = environment.settings.viewQuery()
        query.sort = sort
        return query
    }

    private func persist(_ delta: FolderViewSettings) {
        userChangedView = true
        environment.folderViews.update(folder.directory) { $0 = delta.over($0) }
        if let sort = delta.sort, folder.query.sort != sort {
            var query = folder.query
            query.sort = sort
            folder.setQuery(query)
        }
    }

    /// Re-resolves the current folder and applies what changed (view mode, sort).
    private func reresolve() {
        guard !closed else { return }
        let old = view.resolved
        let resolved = Self.resolve(folder.directory, environment: environment)
        view.replace(resolved)
        if resolved.viewMode != old.viewMode { observers.send(.viewModeChanged(resolved.viewMode)) }
        if folder.query.sort != resolved.sort {
            var query = folder.query
            query.sort = resolved.sort
            folder.setQuery(query)
        }
    }

    private func readFinderView(_ url: URL) {
        let store = environment.folderViews
        guard store.finderView(for: url) == nil, environment.volumes.volume(for: url)?.isLocal ?? false else { return }
        let columns = environment.settings.columns
        let started = ContinuousClock.now
        finderTask = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) {
                FinderFolderView.read(folder: url, globalColumns: columns)
            }.value
            guard let self, !Task.isCancelled, !self.closed else { return }
            store.setFinderView(found ?? FolderViewSettings(), for: url)
            guard self.folder.directory == url, !self.userChangedView, let found, !found.isEmpty,
                  ContinuousClock.now - started < Self.finderApplyDeadline else { return }
            self.reresolve()
        }
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
        case .beginRename, .query:
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
        let settings = environment.settings
        guard folder.query.showHidden != settings.showHidden || folder.query.showAllExtensions != settings.showAllExtensions else { return }
        var query = folder.query
        query.showHidden = settings.showHidden
        query.showAllExtensions = settings.showAllExtensions
        folder.setQuery(query)
    }

    private func showBanner(_ text: String?) {
        guard text != bannerText else { return }
        bannerText = text
        observers.send(.banner(text))
    }
}
