import AppKit
import Core

/// The status bar (§5.5), about 22 pt: `N items`, `M selected (size)` (files only in Phase 1), `X available` for the
/// current volume, and on the trailing end the slot P1-38's operations capsule lives in. The owner supplies the
/// numbers (selection totals from FolderModel.selectionSummary, free space from the Volumes cache); this view only
/// formats them.
@MainActor
final class StatusBarView: NSView {
    private let countLabel = StatusBarView.label(AXID.statusCount)
    private let selectionLabel = StatusBarView.label(AXID.statusSelection)
    private let freeLabel = StatusBarView.label(AXID.statusFree)
    private let slot = NSView()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 22))
        buildLayout()
        update(itemCount: 0, selection: SelectionSummary(count: 0, files: 0, folders: 0, bytes: 0), available: nil)
    }

    required init?(coder: NSCoder) { fatalError("StatusBarView is created in code") }

    /// P1-38 adds the operations capsule here (pinned to all four edges).
    var operationsSlot: NSView { slot }

    var countText: String { countLabel.stringValue }
    var selectionText: String { selectionLabel.stringValue }
    var availableText: String { freeLabel.stringValue }

    func update(itemCount: Int, selection: SelectionSummary, available: Int64?) {
        countLabel.stringValue = StatusText.items(itemCount)
        selectionLabel.stringValue = StatusText.selection(selection)
        freeLabel.stringValue = available.map(StatusText.available) ?? ""
    }

    private func buildLayout() {
        let stack = NSStackView(views: [countLabel, selectionLabel, NSView(), freeLabel, slot])
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let spacer = stack.arrangedSubviews[2]
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        slot.translatesAutoresizingMaskIntoConstraints = false
        slot.setContentHuggingPriority(.required, for: .horizontal)
        let collapsed = slot.widthAnchor.constraint(equalToConstant: 0)
        collapsed.priority = .defaultLow       // zero width until the capsule asks for more
        collapsed.isActive = true
        slot.heightAnchor.constraint(lessThanOrEqualToConstant: 20).isActive = true
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private static func label(_ identifier: String) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setAccessibilityIdentifier(identifier)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
}

/// Status-bar strings (English via L10n; numbers grouped per locale, sizes in the decimal file style).
enum StatusText {
    static func items(_ count: Int) -> String {
        count == 1 ? L10n.string("1 item") : String(format: L10n.string("%@ items"), number(count))
    }

    static func selection(_ summary: SelectionSummary) -> String {
        guard summary.count > 0 else { return "" }
        let count = number(summary.count)
        guard summary.files > 0 else { return String(format: L10n.string("%@ selected"), count) }
        return String(format: L10n.string("%@ selected (%@)"), count, size(summary.bytes))
    }

    static func available(_ bytes: Int64) -> String {
        String(format: L10n.string("%@ available"), size(bytes))
    }

    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    private static func number(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }
}
