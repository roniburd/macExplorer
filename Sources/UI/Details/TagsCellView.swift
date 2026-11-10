import AppKit
import Core

/// The Details Tags column cell (Phase 2's column, P4-05 dots): the coloured dots, then the tag names. Filled from
/// the folder's extended attributes only (never I/O while configuring); rows not loaded yet are empty.
final class TagsCellView: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("macx.cell.tags")
    let dots = TagDotsView(frame: .zero)
    let label = NSTextField(labelWithString: "")
    private var labelLeading: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.reuseID
        dots.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.textColor = .secondaryLabelColor
        label.font = CellStyle.font
        dots.setContentHuggingPriority(.required, for: .horizontal)
        dots.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(dots)
        addSubview(label)
        textField = label
        labelLeading = label.leadingAnchor.constraint(equalTo: dots.trailingAnchor, constant: 0)
        NSLayoutConstraint.activate([
            dots.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            dots.topAnchor.constraint(equalTo: topAnchor),
            dots.bottomAnchor.constraint(equalTo: bottomAnchor),
            labelLeading,
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("TagsCellView is created in code") }

    func configure(tags: [FileTag], text: String, isCut: Bool) {
        dots.tags = tags
        labelLeading.constant = dots.dotColors.isEmpty ? 0 : 4
        label.stringValue = text
        CellStyle.apply(isCut: isCut, to: label, container: self, italicizes: false)
    }
}
