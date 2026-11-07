import AppKit
import Core
import MacxFS

/// The address bar (§5.2): breadcrumb mode by default; edit mode (⌘L, ⌥D, F4, or a click on empty space) shows the
/// POSIX path all selected. Return resolves the text off main (AddressResolver on the target's volume lane): a folder
/// navigates, a file navigates to its parent and selects it, anything else shows inline red text and stays in edit
/// mode. Esc reverts. Successful entries go to Settings.recentLocations (the dropdown's recents).
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
    /// Search results (P3-10): one non-navigating segment instead of the breadcrumb ("Search Results in “X”").
    let searchSegment = NSButton(title: "", target: nil, action: nil)
    /// The title while search results show; nil shows the breadcrumb.
    private(set) var searchTitle: String?
    private(set) var isEditing = false
    private(set) var errorText: String?
    private(set) var currentURL: URL?

    private let environment: CoreEnvironment
    private var editToken = 0
    private var fieldBeforeError: NSLayoutConstraint?
    private var fieldTrailing: NSLayoutConstraint?

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

    /// Shows `url` (breadcrumb from `volume`). While editing, the typed text is kept.
    func show(_ url: URL, volume: VolumeInfo?) {
        currentURL = url
        searchTitle = nil
        breadcrumb.show(BreadcrumbPath.segments(for: url, volume: volume))
        if !isEditing { showDisplayMode() }
    }

    /// Search results (P3-10): one segment titled `title` (magnifying glass); editing (click, ⌘L, ⌥D, F4) starts
    /// from the search root's POSIX path. `show(_:volume:)` restores the breadcrumb.
    func showSearch(title: String, root: URL) {
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
            editField.stringValue = BreadcrumbPath.posixPath(url)
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
        let result = await AddressResolver.resolve(text, current: current, home: environment.settings.home,
                                                   lanes: environment.lanes, mounts: environment.volumes.mountTable)
        guard isEditing, token == editToken else { return }
        switch result {
        case .folder(let url):
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

    // MARK: private

    private func complete(_ url: URL, selecting name: String?, recent: URL) {
        environment.settings.addRecentLocation(BreadcrumbPath.posixPath(recent))
        finishEditing()
        onEndEditing?()
        onNavigate?(url, name)
    }

    private func finishEditing() {
        isEditing = false
        editToken += 1
        editField.resetSuggestions()
        setError(nil)
        if let window, let editor = editField.currentEditor(), window.firstResponder === editor {
            window.makeFirstResponder(nil)
        }
        editField.isHidden = true
        showDisplayMode()
    }

    private func setError(_ text: String?) {
        errorText = text
        errorLabel.stringValue = text ?? ""
        errorLabel.isHidden = text == nil
        // Swap the field's trailing edge so the label gets its full width (it was squeezed to 4 pt: QA round 2).
        if text == nil {
            fieldBeforeError?.isActive = false
            fieldTrailing?.isActive = true
        } else {
            fieldTrailing?.isActive = false
            fieldBeforeError?.isActive = true
        }
    }

    private func wire() {
        breadcrumb.onNavigate = { [weak self] url in self?.onNavigate?(url, nil) }
        breadcrumb.onEmptySpaceClick = { [weak self] in self?.beginEditing() }
        searchSegment.target = self
        searchSegment.action = #selector(searchSegmentClicked(_:))
        let environment = self.environment
        breadcrumb.listSubfolders = { url in
            await SubfolderLister.list(url, readers: environment.readers, showHidden: environment.settings.showHidden)
        }
        editField.suggestionProvider = { [weak self] text in
            guard let self, let current = self.currentURL else { return [] }
            let settings = environment.settings
            let subfolders = await PathCompletion.complete(text, current: current, home: settings.home,
                                                           lanes: environment.lanes, mounts: environment.volumes.mountTable)
            let recents = RecentLocations.matching(text, in: settings.recentLocations)
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
        for view in [breadcrumb, searchSegment, editField, errorLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let fieldTrailing = editField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6)
        self.fieldTrailing = fieldTrailing
        let fieldBeforeError = editField.trailingAnchor.constraint(equalTo: errorLabel.leadingAnchor, constant: -6)
        self.fieldBeforeError = fieldBeforeError
        NSLayoutConstraint.activate([
            breadcrumb.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            breadcrumb.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
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
            heightAnchor.constraint(equalToConstant: 28),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            widthAnchor.constraint(lessThanOrEqualToConstant: 2_000),
        ])
    }
}
