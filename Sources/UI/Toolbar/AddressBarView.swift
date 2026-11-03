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
    private(set) var isEditing = false
    private(set) var errorText: String?
    private(set) var currentURL: URL?

    private let environment: CoreEnvironment
    private var editToken = 0
    private var fieldBeforeError: NSLayoutConstraint?

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
        breadcrumb.show(BreadcrumbPath.segments(for: url, volume: volume))
    }

    /// What the bar shows: the field text while editing, else the breadcrumb ("Volume › a › b").
    var displayText: String { isEditing ? editField.stringValue : breadcrumb.displayText }

    /// ⌘L, ⌥D, F4, empty-space click. Again while editing: selects all.
    func beginEditing() {
        guard let url = currentURL else { return }
        if !isEditing {
            isEditing = true
            editToken += 1
            setError(nil)
            editField.resetSuggestions()
            editField.stringValue = BreadcrumbPath.posixPath(url)
            breadcrumb.isHidden = true
            editField.isHidden = false
        }
        window?.makeFirstResponder(editField)
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
        breadcrumb.isHidden = false
    }

    private func setError(_ text: String?) {
        errorText = text
        errorLabel.stringValue = text ?? ""
        errorLabel.isHidden = text == nil
        fieldBeforeError?.isActive = text != nil
    }

    private func wire() {
        breadcrumb.onNavigate = { [weak self] url in self?.onNavigate?(url, nil) }
        breadcrumb.onEmptySpaceClick = { [weak self] in self?.beginEditing() }
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

    private func buildLayout() {
        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        errorLabel.lineBreakMode = .byTruncatingTail
        errorLabel.isHidden = true
        errorLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        editField.isHidden = true
        for view in [breadcrumb, editField, errorLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let fieldTrailing = editField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6)
        fieldTrailing.priority = .defaultHigh
        let fieldBeforeError = editField.trailingAnchor.constraint(equalTo: errorLabel.leadingAnchor, constant: -6)
        self.fieldBeforeError = fieldBeforeError
        NSLayoutConstraint.activate([
            breadcrumb.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            breadcrumb.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            breadcrumb.topAnchor.constraint(equalTo: topAnchor),
            breadcrumb.bottomAnchor.constraint(equalTo: bottomAnchor),
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
