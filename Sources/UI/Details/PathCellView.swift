import AppKit
import Core

/// Path column cell of a search result (P3-09): the parent folder, "~"-abbreviated and truncated in the middle,
/// with the full path as tooltip and accessibility value.
@MainActor
final class PathCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier(AXID.pathCell)

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseIdentifier
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.truncatesLastVisibleLine = true
        label.textColor = .secondaryLabelColor
        label.font = CellStyle.font
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = label
    }

    required init?(coder: NSCoder) { fatalError("PathCellView is created in code") }

    /// The full parent path (no trailing slash; "/" stays "/") and its "~"-abbreviated form.
    static func text(parent: URL, home: URL) -> (full: String, shown: String) {
        let full = trimmed(parent.path(percentEncoded: false))
        return (full, PathFormatter.tilde(full, home: trimmed(home.path(percentEncoded: false))))
    }

    func configure(parent: URL, home: URL, isCut: Bool = false) {
        let text = Self.text(parent: parent, home: home)
        textField?.stringValue = text.shown
        toolTip = text.full
        setAccessibilityValue(text.full)
        textField?.setAccessibilityValue(text.full)
        if let label = textField { CellStyle.apply(isCut: isCut, to: label, container: self, italicizes: false) }
    }

    private static func trimmed(_ path: String) -> String {
        var path = path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
