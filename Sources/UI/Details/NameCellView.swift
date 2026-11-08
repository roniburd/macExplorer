import AppKit
import Core
import MacxFS

/// Cut rendering (§5.6, §8): 50% opacity and an italic name, so the state doesn't rely on opacity alone.
@MainActor
enum CellStyle {
    static let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    static let italicFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    static let digitsFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    static let smallFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    static let smallItalicFont = NSFontManager.shared.convert(smallFont, toHaveTrait: .italicFontMask)

    static func apply(isCut: Bool, to label: NSTextField, container: NSView, italicizes: Bool = true) {
        if italicizes { label.font = isCut ? italicFont : font }
        container.alphaValue = isCut ? 0.5 : 1
    }
}

final class NameCellView: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("macx.cell.name")
    /// Layout the Details rubber band mirrors to tell the name from blank space without a cell view.
    static let iconLeading: CGFloat = 2
    static let iconTextGap: CGFloat = 6
    let iconView = NSImageView()
    let label = NSTextField(labelWithString: "")
    let cloudBadge = NSImageView()
    private(set) var rowID: RowID?
    private var iconSide: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.reuseID
        for view in [iconView, label, cloudBadge] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        iconView.imageScaling = .scaleProportionallyUpOrDown
        label.lineBreakMode = .byTruncatingMiddle
        label.font = CellStyle.font
        cloudBadge.image = NSImage(systemSymbolName: "icloud", accessibilityDescription: L10n.string("In iCloud, not downloaded"))
        cloudBadge.contentTintColor = .secondaryLabelColor
        imageView = iconView
        textField = label
        iconSide = iconView.widthAnchor.constraint(equalToConstant: 16)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.iconLeading),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconSide,
            iconView.heightAnchor.constraint(equalTo: iconView.widthAnchor),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: Self.iconTextGap),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            cloudBadge.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 4),
            cloudBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            cloudBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            cloudBadge.widthAnchor.constraint(equalToConstant: 14),
        ])
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("NameCellView is created in code") }

    func configure(name: String, icon: CGImage, iconPoints: Double, isCut: Bool, isDataless: Bool, rowID: RowID) {
        self.rowID = rowID
        label.stringValue = name
        setIcon(icon, points: iconPoints)
        cloudBadge.isHidden = !isDataless
        CellStyle.apply(isCut: isCut, to: label, container: self)
        setAccessibilityLabel(isCut ? String(format: L10n.string("%@, cut"), name) : name)
    }

    func setIcon(_ icon: CGImage, points: Double) {
        iconSide.constant = points
        iconView.image = NSImage(cgImage: icon, size: NSSize(width: points, height: points))
    }
}

final class PlainCellView: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("macx.cell.plain")
    let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.reuseID
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.textColor = .secondaryLabelColor
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("PlainCellView is created in code") }

    func configure(text: String, alignment: NSTextAlignment, monospacedDigits: Bool, isCut: Bool,
                   accessibilityLabel: String? = nil) {
        label.stringValue = text
        label.setAccessibilityLabel(accessibilityLabel)
        label.alignment = alignment
        label.font = monospacedDigits ? CellStyle.digitsFont : CellStyle.font
        CellStyle.apply(isCut: isCut, to: label, container: self, italicizes: false)
    }
}
