// Sources/UI/Icons/IconItem.swift
import AppKit
import Core
import MacxFS

/// Two-line label with a middle ellipsis (§5.5). Works on Characters, so graphemes are never split, and keeps the
/// extension visible. Measured with a wrapping text field laid out like the label (its cell insets the text from the
/// frame, so NSString measuring at the full width let candidates overflow and the cell added a second, tail
/// ellipsis: QA round 2). `width` is the label's alignment width (its constraints' width).
@MainActor
enum LabelTruncation {
    private static var twoLineHeights: [NSFont: CGFloat] = [:]
    private static let measuring: NSTextField = {
        let field = NSTextField(wrappingLabelWithString: "")
        field.alignment = .center
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        return field
    }()

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
        let field = measuring
        field.font = font
        field.stringValue = text
        let insets = field.alignmentRectInsets
        let frameWidth = width + insets.left + insets.right
        return field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: frameWidth, height: .greatestFiniteMagnitude)).height ?? 0
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
    /// Tier 2 (P2-17): the Quick Look thumbnail, aspect-fit inside the icon square with a 1 pt separator border.
    let thumbnailView = NSView()
    private(set) var rowID: RowID?
    /// The thumbnail on show, nil while the tier 0/1 icon is shown.
    private(set) var thumbnailKey: ThumbnailKey?
    private var iconSide: NSLayoutConstraint!
    private var thumbnailWidth: NSLayoutConstraint!
    private var thumbnailHeight: NSLayoutConstraint!
    private var shownName = ""
    private var shownWidth: Double = 0
    private var shownCut = false

    override func loadView() {
        let root = NSView()
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 6
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.contentsGravity = .resize
        thumbnailView.layer?.borderWidth = 1
        thumbnailView.isHidden = true
        for part in [highlight, iconView, thumbnailView, label, cloudBadge] as [NSView] {
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
        thumbnailWidth = thumbnailView.widthAnchor.constraint(equalToConstant: 64)
        thumbnailHeight = thumbnailView.heightAnchor.constraint(equalToConstant: 64)
        NSLayoutConstraint.activate([
            highlight.topAnchor.constraint(equalTo: root.topAnchor, constant: 2),
            highlight.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -2),
            highlight.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 2),
            highlight.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -2),
            iconView.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            iconView.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            iconSide,
            iconView.heightAnchor.constraint(equalTo: iconView.widthAnchor),
            thumbnailView.centerXAnchor.constraint(equalTo: iconView.centerXAnchor),
            thumbnailView.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            thumbnailWidth,
            thumbnailHeight,
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
        if name != shownName || labelWidth != shownWidth || isCut != shownCut {
            let font = isCut ? CellStyle.smallItalicFont : CellStyle.smallFont
            label.stringValue = LabelTruncation.twoLineMiddle(name, width: CGFloat(labelWidth), font: font)
            shownName = name
            shownWidth = labelWidth
            shownCut = isCut
        }
        label.toolTip = name
        cloudBadge.isHidden = !isDataless
        view.setAccessibilityLabel(isCut ? String(format: L10n.string("%@, cut"), name) : name)
        applyState(isCut: isCut, isSelected: isSelected, emphasized: emphasized)
    }

    /// The tier 0/1 type or file icon; replaces a thumbnail on show.
    func setIcon(_ icon: CGImage, points: Double) {
        iconSide.constant = points
        iconView.image = NSImage(cgImage: icon, size: NSSize(width: points, height: points))
        if thumbnailKey != nil {
            thumbnailKey = nil
            thumbnailView.layer?.contents = nil
            thumbnailView.isHidden = true
            iconView.isHidden = false
        }
    }

    /// Shows `image` (the cached thumbnail for `key`) aspect-fit inside the `points` icon square.
    func setThumbnail(_ image: CGImage, key: ThumbnailKey, points: Double) {
        iconSide.constant = points
        let w = Double(max(image.width, 1)), h = Double(max(image.height, 1))
        let fit = points / max(w, h)
        thumbnailWidth.constant = max(1, (w * fit).rounded())
        thumbnailHeight.constant = max(1, (h * fit).rounded())
        thumbnailView.layer?.contents = image
        thumbnailKey = key
        thumbnailView.isHidden = false
        iconView.isHidden = true
        updateThumbnailBorder()
    }

    private func updateThumbnailBorder() {
        guard thumbnailKey != nil else { return }
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            thumbnailView.layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateThumbnailBorder()   // the separator colour follows light/dark
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
        updateThumbnailBorder()
    }
}
