import AppKit
import Core
import MacxFS

/// One Columns-view row (P2-19): a 16 pt Tier 0/1 icon, the name (middle truncation) and a trailing chevron for
/// folders. Cut rows are dimmed and italic, as in Details.
final class ColumnCellView: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("macx.cell.column")
    static let iconPoints: Double = 16
    let iconView = NSImageView()
    let label = NSTextField(labelWithString: "")
    let chevron = NSImageView()
    private(set) var rowID: RowID?

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.reuseID
        for view in [iconView, label, chevron] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        iconView.imageScaling = .scaleProportionallyUpOrDown
        label.lineBreakMode = .byTruncatingMiddle
        label.font = CellStyle.font
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        chevron.contentTintColor = .secondaryLabelColor
        chevron.setAccessibilityElement(false)
        imageView = iconView
        textField = label
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Self.iconPoints),
            iconView.heightAnchor.constraint(equalTo: iconView.widthAnchor),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 4),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("ColumnCellView is created in code") }

    func configure(name: String, icon: CGImage, isFolder: Bool, isCut: Bool, rowID: RowID) {
        self.rowID = rowID
        label.stringValue = name
        setIcon(icon)
        chevron.isHidden = !isFolder
        CellStyle.apply(isCut: isCut, to: label, container: self)
        setAccessibilityLabel(isCut ? String(format: L10n.string("%@, cut"), name) : name)
    }

    func setIcon(_ icon: CGImage) {
        iconView.image = NSImage(cgImage: icon, size: NSSize(width: Self.iconPoints, height: Self.iconPoints))
    }
}

/// Columns-view widths (P2-19): the user's last width is `Settings.columnWidth`; the handle's double-click fits the
/// widest name among a column's first 2,000 rows, measured with the cell font, clamped to 120…600 pt.
@MainActor
enum ColumnWidth {
    static let minimum: CGFloat = 120
    static let maximum: CGFloat = 600
    static let fitSampleLimit = 2_000
    /// Icon, gaps, chevron and the resize handle around the name.
    static let chrome: CGFloat = 4 + CGFloat(ColumnCellView.iconPoints) + 6 + 4 + 8 + 6 + ColumnResizeHandle.width + 4

    static func clamp(_ width: CGFloat) -> CGFloat { min(maximum, max(minimum, width)) }

    static func fit(names: [String], font: NSFont) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let widest = names.prefix(fitSampleLimit).reduce(CGFloat(0)) { max($0, ($1 as NSString).size(withAttributes: attributes).width) }
        return clamp(ceil(widest + chrome))
    }
}

/// The 6 pt handle at a column's trailing edge: drag resizes that column, double-click auto-fits it.
final class ColumnResizeHandle: NSView {
    static let width: CGFloat = 6
    var onBegin: (() -> Void)?
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    private var startX: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("ColumnResizeHandle is created in code") }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?(); return }
        startX = event.locationInWindow.x
        onBegin?()
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(event.locationInWindow.x - startX)
    }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount < 2 { onEnd?() }
    }
}
