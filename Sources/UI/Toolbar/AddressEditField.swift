import AppKit

/// Edit mode of the address bar (§5.2): the path text field with a debounced autocomplete dropdown of subfolders and
/// recent locations. ↓/↑ move the highlight, Return accepts the highlighted row (or submits the text), Tab completes it,
/// Esc closes the list first and then cancels. Every other key, including the colliding ones (⌘↑, ⌘⌫, ⌥←, …),
/// is plain text editing (§5.6 rule 1).
@MainActor
final class AddressEditField: NSTextField, NSTextFieldDelegate {
    /// Suggestions for the typed text (off main through Core; installed by AddressBarView).
    var suggestionProvider: ((String) async -> [AddressSuggestion])?
    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onTextChange: (() -> Void)?
    /// The field editor resigned (focus moved elsewhere).
    var onEndEditing: (() -> Void)?
    var debounce: Duration = .milliseconds(120)

    private(set) var suggestions: [AddressSuggestion] = []
    private let list = AddressSuggestionList()
    private var debounceTask: Task<Void, Never>?
    private var suggestionGeneration = 0

    init() {
        super.init(frame: .zero)
        delegate = self
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        usesSingleLineMode = true
        cell?.isScrollable = true
        cell?.wraps = false
        lineBreakMode = .byClipping
        font = .systemFont(ofSize: NSFont.systemFontSize)
        setAccessibilityIdentifier(AXID.addressField)
        identifier = NSUserInterfaceItemIdentifier(AXID.addressField)
        setAccessibilityLabel(L10n.string("Address"))
        list.onChoose = { [weak self] index in self?.accept(index, submit: true) }
    }

    required init?(coder: NSCoder) { fatalError("created in code") }

    var isShowingSuggestions: Bool { list.isVisible }
    var selectedSuggestion: Int? { list.selectedIndex }

    /// Fetches and shows suggestions for `text` now (cancels a pending debounced fetch).
    func updateSuggestions(for text: String) async {
        debounceTask?.cancel()
        debounceTask = nil
        await fetchSuggestions(for: text)
    }

    func hideSuggestions() {
        debounceTask?.cancel()
        debounceTask = nil
        suggestionGeneration += 1
        list.hide()
    }

    /// A new or finished edit: no list and no stale rows for ↓ to reopen.
    func resetSuggestions() {
        hideSuggestions()
        suggestions = []
    }

    /// Replaces the text being edited, caret at the end.
    func replaceText(_ text: String) {
        if let editor = currentEditor() {
            editor.string = text
            editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        } else {
            stringValue = text
        }
    }

    // MARK: suggestions

    private func scheduleSuggestions() {
        debounceTask?.cancel()
        let delay = debounce
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await self.fetchSuggestions(for: self.stringValue)
        }
    }

    private func fetchSuggestions(for text: String) async {
        suggestionGeneration += 1
        let generation = suggestionGeneration
        let items = await suggestionProvider?(text) ?? []
        guard generation == suggestionGeneration, !isHidden else { return }
        suggestions = items
        if items.isEmpty { list.hide() } else { list.show(items, below: self) }
    }

    private func accept(_ index: Int, submit: Bool) {
        guard suggestions.indices.contains(index) else { return }
        let text = suggestions[index].text
        replaceText(text)
        hideSuggestions()
        if submit { onSubmit?(text) } else { scheduleSuggestions() }
    }

    private func moveHighlight(by delta: Int) -> Bool {
        if !list.isVisible {
            guard !suggestions.isEmpty else { return false }
            list.show(suggestions, below: self)
        }
        let count = suggestions.count
        guard count > 0 else { return false }
        let next: Int
        if let current = list.selectedIndex {
            next = min(max(current + delta, 0), count - 1)
        } else {
            next = delta > 0 ? 0 : count - 1
        }
        list.select(next)
        return true
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        onTextChange?()
        scheduleSuggestions()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        hideSuggestions()
        onEndEditing?()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            return moveHighlight(by: 1)
        case #selector(NSResponder.moveUp(_:)):
            return list.isVisible ? moveHighlight(by: -1) : false
        case #selector(NSResponder.insertNewline(_:)):
            if list.isVisible, let index = list.selectedIndex {
                accept(index, submit: true)
            } else {
                hideSuggestions()
                onSubmit?(textView.string)
            }
            return true
        case #selector(NSResponder.insertTab(_:)):
            guard list.isVisible, !suggestions.isEmpty else { return false }
            accept(list.selectedIndex ?? 0, submit: false)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if list.isVisible {
                hideSuggestions()
            } else {
                onCancel?()
            }
            return true
        default:
            return false
        }
    }
}
