// Sources/UI/Icons/IconItem.swift
import AppKit
import Core
import MacxFS

/// Two-line label with a middle ellipsis (§5.5). Works on Characters, so graphemes are never split, and keeps the
/// extension visible. Measured with the same text system the label uses.
@MainActor
enum LabelTruncation {
    private static var twoLineHeights: [NSFont: CGFloat] = [:]

    static func twoLineMiddle(_ name: String, width: CGFloat, font: NSFont) -> String {
        let limit = twoLineHeight(font) + 0.5
        if height(of: name, width: width, font: font) <= limit { return name }
        let characters = Array(name)
        let extensionLength = name.lastIndex(of: ".").map { name.distance(from: $0, to: name.endIndex) } ?? 0
        var low = 0
        var high = characters.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if height(of: candidate(characters, keep: mid, extensionLength: extensionLength), width: width, font: font) <= limit {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return candidate(characters, keep: low, extensionLength: extensionLength)
    }

    /// Keeps `keep` characters: half from the start, and from the end at least the extension plus three characters.
    static func candidate(_ characters: [Character], keep: Int, extensionLength: Int) -> String {
        let tail = min(keep, max(keep / 2, min(extensionLength, 12) + 3))
        let head = keep - tail
        return String(characters[0..<head]) + "…" + String(characters[(characters.count - tail)...])
    }

    private static func height(of text: String, width: CGFloat, font: NSFont) -> CGFloat {
        (text as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                        options: [.usesLineFragmentOrigin], attributes: [.font: font]).height
    }

    private static func twoLineHeight(_ font: NSFont) -> CGFloat {
        if let cached = twoLineHeights[font] { return cached }
        let value = height(of: "X\nX", width: 1_000, font: font)
        twoLineHeights[font] = value
        return value
    }
}

final class IconItem: NSCollectionViewItem {
    static let reuseID = NSUserInterfaceItemIdentifier("macx.iconItem")
    let iconView = NSImageView()
    let label = NSTextField(wrappingLabelWithString: "")
    let highlight = NSView()
    let cloudBadge = NSImageView()
    private(set) var rowID: RowID?
    private var iconSide: NSLayoutConstraint!
    private var shownName = ""
    private var shownWidth: Double = 0

    override func loadView() {
        let root = NSView()
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 6
        for part in [highlight, iconView, label, cloudBadge] as [NSView] {
            part.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(part)
        }
        iconView.imageScaling = .scaleProportionallyUpOrDown
        label.alignment = .center
        label.font = CellStyle.smallFont
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byWordWrapping
        label.cell?.truncatesLastVisibleLine = true
        cloudBadge.image = NSImage(systemSymbolName: "icloud", accessibilityDescription: L10n.string("In iCloud, not downloaded"))
        cloudBadge.contentTintColor = .secondaryLabelColor
        iconSide = iconView.widthAnchor.constraint(equalToConstant: 64)
        NSLayoutConstraint.activate([
            highlight.topAnchor.constraint(equalTo: root.topAnchor, constant: 2),
            highlight.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -2),
            highlight.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 2),
            highlight.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -2),
            iconView.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            iconView.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            iconSide,
            iconView.heightAnchor.constraint(equalTo: iconView.widthAnchor),
            label.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            label.heightAnchor.constraint(equalToConstant: GridMetrics.labelHeight),
            cloudBadge.trailingAnchor.constraint(equalTo: iconView.trailingAnchor),
            cloudBadge.bottomAnchor.constraint(equalTo: iconView.bottomAnchor),
            cloudBadge.widthAnchor.constraint(equalToConstant: 14),
        ])
        view = root
    }

    func configure(name: String, icon: CGImage, points: Double, labelWidth: Double, isCut: Bool, isSelected: Bool,
                   emphasized: Bool, isDataless: Bool, rowID: RowID) {
        self.rowID = rowID
        setIcon(icon, points: points)
        if name != shownName || labelWidth != shownWidth {
            label.stringValue = LabelTruncation.twoLineMiddle(name, width: CGFloat(labelWidth), font: CellStyle.smallFont)
            shownName = name
            shownWidth = labelWidth
        }
        label.toolTip = name
        cloudBadge.isHidden = !isDataless
        view.setAccessibilityLabel(isCut ? String(format: L10n.string("%@, cut"), name) : name)
        applyState(isCut: isCut, isSelected: isSelected, emphasized: emphasized)
    }

    func setIcon(_ icon: CGImage, points: Double) {
        iconSide.constant = points
        iconView.image = NSImage(cgImage: icon, size: NSSize(width: points, height: points))
    }

    /// Selection is drawn from the model (§5.5); cut items are dimmed and italic (§8).
    func applyState(isCut: Bool, isSelected: Bool, emphasized: Bool) {
        view.alphaValue = isCut ? 0.5 : 1
        label.font = isCut ? CellStyle.smallItalicFont : CellStyle.smallFont
        label.textColor = isSelected && emphasized ? .alternateSelectedControlTextColor : .labelColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            let color: NSColor? = isSelected ? (emphasized ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor) : nil
            highlight.layer?.backgroundColor = color?.cgColor
        }
    }
}
