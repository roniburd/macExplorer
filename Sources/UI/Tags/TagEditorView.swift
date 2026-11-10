import AppKit
import SwiftUI
import Core

/// One token in the tag field.
final class TagToken: NSObject {
    let tag: FileTag
    init(_ tag: FileTag) { self.tag = tag }
}

/// The `NSTokenField` behind the tag editor (P4-05). Completions are the known tags filtered by prefix; Return on
/// a new name makes a token with no colour; each token's menu sets one of the seven colours (or none). Tags only
/// some selected items have draw as plain (unbezeled) tokens. Edits commit when editing ends.
@MainActor
final class TagTokenFieldController: NSObject, NSTokenFieldDelegate {
    let model: TagEditorModel
    let field = NSTokenField()
    private var shownRevision = -1

    init(model: TagEditorModel) {
        self.model = model
        super.init()
        field.delegate = self
        field.tokenStyle = .rounded
        field.completionDelay = 0
        field.placeholderString = L10n.string("Add Tags")
        field.setAccessibilityIdentifier("macx.tags.field")
        field.setAccessibilityLabel(L10n.string("Tags"))
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.lineBreakMode = .byWordWrapping
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        refresh()
    }

    /// Shows the model's tokens when the model reloaded (never while the user is mid-edit on the same revision).
    func refresh() {
        guard model.revision != shownRevision else { return }
        shownRevision = model.revision
        field.objectValue = model.tokens.map(TagToken.init)
    }

    /// The tags the field shows now: tokens plus any typed text not yet tokenized.
    private func fieldTags() -> [FileTag] {
        let values = (field.objectValue as? [Any]) ?? []
        return values.compactMap { value -> FileTag? in
            if let token = value as? TagToken { return token.tag }
            if let text = value as? String { return model.token(forTyped: text) }
            return nil
        }
    }

    /// Ends editing in the field and commits what it shows.
    func commit() {
        if let window = field.window, let editor = field.currentEditor(), window.firstResponder === editor {
            window.makeFirstResponder(nil)        // ends editing → controlTextDidEndEditing commits
            return
        }
        syncAndCommit()
    }

    private func syncAndCommit() {
        model.tokens = TagIO.normalize(fieldTags())
        Task { [model] in await model.commit() }
    }

    // MARK: NSControlTextEditingDelegate

    func controlTextDidEndEditing(_ obj: Notification) { syncAndCommit() }

    // MARK: NSTokenFieldDelegate

    func tokenField(_ tokenField: NSTokenField, completionsForSubstring substring: String, indexOfToken tokenIndex: Int,
                    indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?) -> [Any]? {
        selectedIndex?.pointee = -1
        return model.completions(for: substring)
    }

    func tokenField(_ tokenField: NSTokenField, representedObjectForEditing editingString: String) -> Any? {
        model.token(forTyped: editingString).map(TagToken.init)
    }

    func tokenField(_ tokenField: NSTokenField, displayStringForRepresentedObject representedObject: Any) -> String? {
        (representedObject as? TagToken)?.tag.name ?? representedObject as? String
    }

    func tokenField(_ tokenField: NSTokenField, editingStringForRepresentedObject representedObject: Any) -> String? {
        (representedObject as? TagToken)?.tag.name ?? representedObject as? String
    }

    func tokenField(_ tokenField: NSTokenField, styleForRepresentedObject representedObject: Any) -> NSTokenField.TokenStyle {
        guard let token = representedObject as? TagToken else { return .rounded }
        return model.isMixed(token.tag.name) ? .plainSquared : .rounded
    }

    func tokenField(_ tokenField: NSTokenField, hasMenuForRepresentedObject representedObject: Any) -> Bool {
        representedObject is TagToken
    }

    func tokenField(_ tokenField: NSTokenField, menuForRepresentedObject representedObject: Any) -> NSMenu? {
        guard let token = representedObject as? TagToken else { return nil }
        return Self.colorMenu(current: token.tag.color) { [weak self] color in self?.setColor(color, of: token) }
    }

    /// No colour, then the seven colours in Finder's order.
    static func colorMenu(current: TagColor, choose: @escaping @MainActor (TagColor) -> Void) -> NSMenu {
        let menu = NSMenu(title: L10n.string("Tag Color"))
        let colors: [TagColor] = [.none, .red, .orange, .yellow, .green, .blue, .purple, .gray]
        for color in colors {
            let item = ClosureMenuItem(title: title(for: color)) { choose(color) }
            item.image = TagDotsView.menuImage(for: color)
            item.state = color == current ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    static func title(for color: TagColor) -> String {
        switch color {
        case .none: L10n.string("No Color")
        case .red: L10n.string("Red")
        case .orange: L10n.string("Orange")
        case .yellow: L10n.string("Yellow")
        case .green: L10n.string("Green")
        case .blue: L10n.string("Blue")
        case .purple: L10n.string("Purple")
        case .gray: L10n.string("Gray")
        }
    }

    private func setColor(_ color: TagColor, of token: TagToken) {
        var tags = fieldTags()
        guard let index = tags.firstIndex(where: { TagEditorModel.key($0.name) == TagEditorModel.key(token.tag.name) }) else { return }
        tags[index].color = color
        field.objectValue = tags.map(TagToken.init)
        syncAndCommit()
    }
}

/// SwiftUI wrapper for the Properties "Tags" row.
struct TagEditorView: NSViewRepresentable {
    let model: TagEditorModel

    func makeCoordinator() -> TagTokenFieldController { TagTokenFieldController(model: model) }

    func makeNSView(context: Context) -> NSTokenField { context.coordinator.field }

    func updateNSView(_ nsView: NSTokenField, context: Context) {
        _ = model.revision             // observe reloads
        context.coordinator.refresh()
    }

    static func dismantleNSView(_ nsView: NSTokenField, coordinator: TagTokenFieldController) {
        coordinator.commit()
    }
}

/// Edit Tags… (P4-05): the editor in a popover anchored at the first selected row. Closing it commits.
@MainActor
final class TagEditorPopoverController: NSViewController, NSPopoverDelegate {
    let model: TagEditorModel
    let tokens: TagTokenFieldController

    init(model: TagEditorModel) {
        self.model = model
        self.tokens = TagTokenFieldController(model: model)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("TagEditorPopoverController is created in code") }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 44))
        let field = tokens.field
        field.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            field.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            field.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
            container.widthAnchor.constraint(equalToConstant: 280),
        ])
        view = container
        observeModel()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(tokens.field)
    }

    /// Follows reloads (the first load arrives after the popover opened).
    private func observeModel() {
        withObservationTracking { _ = model.revision } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.tokens.refresh()
                self.observeModel()
            }
        }
    }

    func popoverWillClose(_ notification: Notification) { tokens.commit() }
}
