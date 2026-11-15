import AppKit
import Core
import MacxFS
import MacxPluginKit

/// The address bar (§5.2): breadcrumb mode by default; edit mode (⌘L, ⌥D, F4, or a click on empty space) shows the
/// POSIX path all selected. Return resolves the text off main (AddressResolver on the target's volume lane): a folder
/// navigates, a file navigates to its parent and selects it, anything else shows inline red text and stays in edit
/// mode. Esc reverts. Successful entries go to Settings.recentLocations (the dropdown's recents).
/// Remote work shows a spinner and a status at the bar's trailing edge: "Connecting to X…" while a typed remote
/// address resolves, "Switching to dev…" from a ref choice until that ref's folder has loaded, and "Loading…" while
/// a remote folder is still listing (after a short delay, so a fast listing doesn't flash it).
@MainActor
final class AddressBarView: NSView {
    var onNavigate: ((URL, String?) -> Void)?
    /// Edit mode ended by Return or Esc (not by focus moving elsewhere): the window focuses the content.
    var onEndEditing: (() -> Void)?
    /// Tab / ⇧Tab while editing: the edit reverts and the window moves along the §5.6 cycle (`true` = forward).
    var onCycleFocus: ((Bool) -> Void)?

    let breadcrumb = BreadcrumbView(frame: .zero)
    let editField = AddressEditField()
    let errorLabel = NSTextField(labelWithString: "")
    let activitySpinner = NSProgressIndicator()
    let activityLabel = NSTextField(labelWithString: "")
    private let activityView = NSStackView()
    /// Search results (P3-10): one non-navigating segment instead of the breadcrumb ("Search Results in “X”").
    let searchSegment = NSButton(title: "", target: nil, action: nil)
    /// The ref chip after a remote folder's root segment (spec §4.2).
    let refChip = RefChipController()
    /// The title while search results show; nil shows the breadcrumb.
    private(set) var searchTitle: String?
    private(set) var isEditing = false
    private(set) var errorText: String?
    private(set) var currentURL: URL?
    /// The status beside the spinner; nil when nothing remote is in flight.
    private(set) var activityText: String?

    /// How long a remote folder must be listing before "Loading…" shows.
    static let loadingDelay: Duration = .milliseconds(300)

    /// The root segment's symbol for a remote folder whose provider isn't registered.
    static let missingProviderSymbol = "questionmark.folder"

    private let environment: CoreEnvironment
    private var editToken = 0
    /// Bumped by each ref choice and each move to another folder: a ref switch still listing the new ref when the
    /// user moves on (or picks again) must not drag the window back when it finishes.
    private var refSwitchToken = 0
    private var fieldBeforeError: NSLayoutConstraint?
    private var fieldTrailing: NSLayoutConstraint?
    private var fieldBeforeActivity: NSLayoutConstraint?
    private var breadcrumbTrailing: NSLayoutConstraint?
    private var breadcrumbBeforeActivity: NSLayoutConstraint?
    /// A typed remote address resolving: its text, and the edit (`editToken`) that started it.
    private var connecting: (text: String, token: Int)?
    /// A ref choice in flight: its text, the choice (`refSwitchToken`), and once resolved the folder it opens; it
    /// ends when that folder stops loading, the bar moves elsewhere, or a newer choice replaces it.
    private var switching: (text: String, token: Int, target: URL?)?
    /// The current remote folder is listing (`setFolderLoading`); `showsLoading` turns on after `loadingDelay`.
    private var folderLoading = false
    private var showsLoading = false
    private var loadingDelayTask: Task<Void, Never>?

    init(context: UIContext) {
        environment = context.environment
        super.init(frame: NSRect(x: 0, y: 0, width: 480, height: 28))
        breadcrumb.dropTarget = DropTarget(context: context, originView: breadcrumb)
        setAccessibilityIdentifier(AXID.addressBar)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(L10n.string("Address"))
        buildLayout()
        wire()
    }

    required init?(coder: NSCoder) { fatalError("created in code") }

    /// Shows `url` (breadcrumb from `volume`; a remote folder's from its provider, with the ref chip). While editing,
    /// the typed text is kept.
    func show(_ url: URL, volume: VolumeInfo?) {
        if url != currentURL {
            refSwitchToken += 1
            if let switching, switching.target != url { self.switching = nil }
        }
        currentURL = url
        searchTitle = nil
        if let location = RemoteLocation(url: url) {
            if let provider = environment.remote.provider(id: location.provider) {
                breadcrumb.show(BreadcrumbPath.remoteSegments(for: location, rootTitle: provider.displayRoot(location),
                                                              symbol: provider.iconSymbol))
                refChip.show(location: location, provider: provider)
                breadcrumb.accessoryAfterRoot = refChip.button
            } else {
                // Provider removed or disabled (a restored window, a stale favorite): still remote segments, never
                // the URL read as a POSIX path (Review Focus #2); no ref chip without a provider to list refs.
                breadcrumb.show(BreadcrumbPath.remoteSegments(for: location, rootTitle: location.repo,
                                                              symbol: Self.missingProviderSymbol))
                breadcrumb.accessoryAfterRoot = nil
            }
        } else {
            breadcrumb.show(BreadcrumbPath.segments(for: url, volume: volume))
            breadcrumb.accessoryAfterRoot = nil
        }
        if !isEditing { showDisplayMode() }
    }

    /// Search results (P3-10): one segment titled `title` (magnifying glass); editing (click, ⌘L, ⌥D, F4) starts
    /// from the search root's POSIX path. `show(_:volume:)` restores the breadcrumb.
    func showSearch(title: String, root: URL) {
        refSwitchToken += 1
        currentURL = root
        searchTitle = title
        searchSegment.title = title
        searchSegment.toolTip = BreadcrumbPath.posixPath(root)
        searchSegment.setAccessibilityLabel(title)
        if !isEditing { showDisplayMode() }
    }

    /// What the bar shows: the field text while editing, else the search title or the breadcrumb ("Volume › a › b").
    var displayText: String { isEditing ? editField.stringValue : (searchTitle ?? breadcrumb.displayText) }

    private func showDisplayMode() {
        breadcrumb.isHidden = searchTitle != nil
        searchSegment.isHidden = searchTitle == nil
    }

    /// ⌘L, ⌥D, F4, empty-space click. Again while editing: selects all.
    func beginEditing() {
        guard let url = currentURL else { return }
        if !isEditing {
            isEditing = true
            editToken += 1
            setError(nil)
            editField.resetSuggestions()
            editField.resetUndo()
            editField.stringValue = addressText(for: url)
            breadcrumb.isHidden = true
            searchSegment.isHidden = true
            editField.isHidden = false
        }
        // Already editing in the field: re-focusing it would resign its field editor, which ends edit mode
        // (controlTextDidEndEditing → finishEditing). Only select all and clear the error (QA round 3).
        if let editor = editField.currentEditor(), window?.firstResponder === editor {
            setError(nil)
        } else {
            window?.makeFirstResponder(editField)
        }
        editField.currentEditor()?.selectAll(nil)
    }

    /// Esc: back to the breadcrumb without navigating.
    func cancelEditing() {
        guard isEditing else { return }
        finishEditing()
        onEndEditing?()
    }

    /// Resolves `text` and acts on it (Return). Ignored unless editing, and dropped if editing ended or restarted
    /// while the lane was resolving.
    func submit(_ text: String) async {
        guard isEditing, let current = currentURL else { return }
        let token = editToken
        if let target = AddressResolver.remoteTarget(text, current: current, registry: environment.remote) {
            connecting = (connectingText(for: target, current: current), token)
            updateActivity()
        }
        let result = await AddressResolver.resolve(text, current: current, home: environment.settings.home,
                                                   lanes: environment.lanes, mounts: environment.volumes.mountTable,
                                                   remote: environment.remote)
        if connecting?.token == token {
            connecting = nil
            updateActivity()
        }
        guard isEditing, token == editToken else { return }
        switch result {
        case .folder(let url), .remote(let url):
            complete(url, selecting: nil, recent: url)
        case .file(_, let name) where name.hasPrefix(".") && !environment.settings.showHidden:
            // It would be listed but not shown, so nothing could be selected: say why instead (QA round 1).
            setError(String(format: L10n.string("'%@' is hidden (⇧⌘. shows hidden items)"), name))
        case .file(let parent, let name):
            complete(parent, selecting: name, recent: parent)
        case .notFound(let input):
            setError(String(format: L10n.string("Can't find '%@'"), input))
        case .noAccess(let input):
            setError(String(format: L10n.string("Can't open '%@'"), input))
        }
    }

    /// Phase 4's tests type into the bar this way: enters edit mode if needed, then submits.
    func submitForTesting(_ text: String) async {
        beginEditing()
        editField.stringValue = text
        await submit(text)
    }

    /// The window's current folder is remote and still listing (false for local folders and once listed).
    func setFolderLoading(_ loading: Bool) {
        if !loading, let switching, switching.target != nil, switching.target == currentURL { self.switching = nil }
        guard loading != folderLoading else { return updateActivity() }
        folderLoading = loading
        loadingDelayTask?.cancel()
        loadingDelayTask = nil
        showsLoading = false
        if loading {
            loadingDelayTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.loadingDelay)
                guard let self, !Task.isCancelled, self.folderLoading else { return }
                self.showsLoading = true
                self.updateActivity()
            }
        }
        updateActivity()
    }

    // MARK: private

    /// "Connecting to X…" for another repository (or ref) than the current folder's; "Loading…" inside it.
    private func connectingText(for target: RemoteLocation, current: URL) -> String {
        if let here = RemoteLocation(url: current), here.provider == target.provider, here.repo == target.repo,
           target.ref == nil || target.ref == here.ref {
            return L10n.string("Loading…")
        }
        let root = environment.remote.provider(id: target.provider)?.displayRoot(target) ?? target.repo
        return String(format: L10n.string("Connecting to %@…"), root)
    }

    private func updateActivity() {
        let text = connecting?.text ?? switching?.text ?? (showsLoading ? L10n.string("Loading…") : nil)
        guard text != activityText else { return }
        activityText = text
        activityLabel.stringValue = text ?? ""
        activityView.isHidden = text == nil
        activityView.setAccessibilityLabel(text)
        if text == nil { activitySpinner.stopAnimation(nil) } else { activitySpinner.startAnimation(nil) }
        updateTrailingLayout()
    }

    /// The field and the breadcrumb end before whichever of the error and the activity shows, else at the edge.
    private func updateTrailingLayout() {
        let busy = activityText != nil
        let failed = errorText != nil && !busy
        errorLabel.isHidden = !failed
        fieldTrailing?.isActive = false
        fieldBeforeError?.isActive = false
        fieldBeforeActivity?.isActive = false
        breadcrumbTrailing?.isActive = !busy
        breadcrumbBeforeActivity?.isActive = busy
        (busy ? fieldBeforeActivity : failed ? fieldBeforeError : fieldTrailing)?.isActive = true
    }

    private func complete(_ url: URL, selecting name: String?, recent: URL) {
        environment.settings.addRecentLocation(addressText(for: recent))
        environment.settings.addRecentRepository(recent)     // no-op for local folders
        finishEditing()
        onEndEditing?()
        onNavigate?(url, name)
    }

    /// What edit mode shows and recents keep: the POSIX path; for a remote folder its provider web address (typing it
    /// back resolves to the same place), else the remote URL itself (also accepted by the resolver).
    func addressText(for url: URL) -> String {
        guard let location = RemoteLocation(url: url) else { return BreadcrumbPath.posixPath(url) }
        return environment.remote.provider(id: location.provider)?.webURL(location)?.absoluteString ?? url.absoluteString
    }

    private func finishEditing() {
        isEditing = false
        editToken += 1
        editField.resetSuggestions()
        setError(nil)
        if connecting != nil {
            connecting = nil
            updateActivity()
        }
        if let window, let editor = editField.currentEditor(), window.firstResponder === editor {
            window.makeFirstResponder(nil)
        }
        editField.isHidden = true
        showDisplayMode()
    }

    private func setError(_ text: String?) {
        errorText = text
        errorLabel.stringValue = text ?? ""
        // Swap the field's trailing edge so the label gets its full width (it was squeezed to 4 pt: QA round 2).
        updateTrailingLayout()
    }

    private func wire() {
        breadcrumb.onNavigate = { [weak self] url in self?.onNavigate?(url, nil) }
        breadcrumb.onEmptySpaceClick = { [weak self] in self?.beginEditing() }
        searchSegment.target = self
        searchSegment.action = #selector(searchSegmentClicked(_:))
        let environment = self.environment
        breadcrumb.listSubfolders = { url in
            await SubfolderLister.list(url, readers: environment.readers, remote: environment.remote,
                                       showHidden: environment.settings.showHidden)
        }
        refChip.onChoose = { [weak self] ref in
            guard let self, let location = self.refChip.location else { return }
            self.refSwitchToken += 1
            let token = self.refSwitchToken
            self.switching = (String(format: L10n.string("Switching to %@…"), RefChipController.shortRef(ref)), token, nil)
            self.updateActivity()
            Task { @MainActor [weak self] in
                guard let self else { return }
                let target = await RefSwitch.target(from: location, to: ref, registry: self.environment.remote)
                guard token == self.refSwitchToken, self.currentURL == location.url else {
                    if self.switching?.token == token {
                        self.switching = nil
                        self.updateActivity()
                    }
                    return
                }
                // Same folder (the current ref again): nothing will load, so nothing ends the switch but this.
                self.switching = target.url == location.url ? nil : (self.switching?.text ?? "", token, target.url)
                self.updateActivity()
                self.onNavigate?(target.url, nil)
            }
        }
        editField.suggestionProvider = { [weak self] text in
            guard let self, let current = self.currentURL else { return [] }
            let settings = environment.settings
            let remote = await RemoteCompletion.complete(text, current: current, registry: environment.remote)
            let recents = remote.suggestions + RecentLocations.matching(text, in: settings.recentLocations)
            // File completion only for file text: a remote `current` must never reach the POSIX path math.
            let isFileText = text.hasPrefix("/") || text.hasPrefix("~") || (current.isFileURL && remote.subfolders.isEmpty
                && AddressResolver.remoteTarget(text, current: current, registry: environment.remote) == nil)
            let subfolders = isFileText
                ? await PathCompletion.complete(text, current: current, home: settings.home,
                                                lanes: environment.lanes, mounts: environment.volumes.mountTable)
                : remote.subfolders
            return AddressSuggestions.make(for: text, subfolders: subfolders, recents: recents)
        }
        editField.onSubmit = { [weak self] text in
            Task { @MainActor [weak self] in await self?.submit(text) }
        }
        editField.onCancel = { [weak self] in self?.cancelEditing() }
        editField.onCycleFocus = { [weak self] forward in
            guard let self else { return }
            if self.isEditing { self.finishEditing() }
            self.onCycleFocus?(forward)
        }
        editField.onTextChange = { [weak self] in self?.setError(nil) }
        editField.onEndEditing = { [weak self] in
            // Focus moved elsewhere (click in the content, Tab): revert quietly.
            guard let self, self.isEditing else { return }
            self.finishEditing()
        }
    }

    @objc private func searchSegmentClicked(_ sender: Any?) { beginEditing() }

    private func buildLayout() {
        searchSegment.bezelStyle = .accessoryBarAction
        searchSegment.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchSegment.imagePosition = .imageLeading
        searchSegment.lineBreakMode = .byTruncatingMiddle
        searchSegment.alignment = .left
        searchSegment.isHidden = true
        searchSegment.setAccessibilityIdentifier(AXID.searchResultsTitle)
        searchSegment.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        errorLabel.lineBreakMode = .byTruncatingTail
        errorLabel.isHidden = true
        errorLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        editField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        editField.isHidden = true
        activitySpinner.style = .spinning
        activitySpinner.controlSize = .small
        activitySpinner.isDisplayedWhenStopped = false
        activityLabel.textColor = .secondaryLabelColor
        activityLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        activityLabel.lineBreakMode = .byTruncatingTail
        activityLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        activityView.orientation = .horizontal
        activityView.spacing = 4
        activityView.addArrangedSubview(activitySpinner)
        activityView.addArrangedSubview(activityLabel)
        activityView.isHidden = true
        activityView.setAccessibilityElement(true)
        activityView.setAccessibilityRole(.progressIndicator)
        activityView.setAccessibilityIdentifier(AXID.addressActivity)
        for view in [breadcrumb, searchSegment, editField, errorLabel, activityView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let fieldTrailing = editField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6)
        self.fieldTrailing = fieldTrailing
        let fieldBeforeError = editField.trailingAnchor.constraint(equalTo: errorLabel.leadingAnchor, constant: -6)
        self.fieldBeforeError = fieldBeforeError
        fieldBeforeActivity = editField.trailingAnchor.constraint(equalTo: activityView.leadingAnchor, constant: -6)
        let breadcrumbTrailing = breadcrumb.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2)
        self.breadcrumbTrailing = breadcrumbTrailing
        breadcrumbBeforeActivity = breadcrumb.trailingAnchor.constraint(equalTo: activityView.leadingAnchor, constant: -6)
        NSLayoutConstraint.activate([
            breadcrumb.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            breadcrumbTrailing,
            breadcrumb.topAnchor.constraint(equalTo: topAnchor),
            breadcrumb.bottomAnchor.constraint(equalTo: bottomAnchor),
            searchSegment.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            searchSegment.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            searchSegment.centerYAnchor.constraint(equalTo: centerYAnchor),
            editField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            editField.centerYAnchor.constraint(equalTo: centerYAnchor),
            fieldTrailing,
            errorLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            errorLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            errorLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.5),
            activityView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            activityView.centerYAnchor.constraint(equalTo: centerYAnchor),
            activityView.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.5),
            heightAnchor.constraint(equalToConstant: 28),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            widthAnchor.constraint(lessThanOrEqualToConstant: 2_000),
        ])
    }
}
