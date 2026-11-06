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
    var viewMode: ViewMode {
        didSet { if viewMode != oldValue { observers.send(.viewModeChanged(viewMode)) } }
    }

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
        self.folder = environment.makeFolderModel(initialURL)
        self.history = NavigationHistory(current: initialURL)
        self.viewMode = environment.settings.viewMode
        attach(folder)
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
        let model = environment.makeFolderModel(url)
        folder = model
        pendingSelection = name
        attach(model)
        observers.send(.folderChanged(model))
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
