import AppKit
import Core

/// Finder-style tag dots (P4-05): up to 3 overlapping 8 pt dots for the coloured tags, the most recently added
/// drawn last (on top), then "+N" when more coloured tags exist. Colourless tags get no dot but are in the
/// accessibility label. Draws nothing for no tags.
@MainActor
final class TagDotsView: NSView {
    static let dotDiameter: CGFloat = 8
    static let dotOverlap: CGFloat = 3
    static let maxDots = 3

    var tags: [FileTag] = [] {
        didSet {
            guard tags != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
            setAccessibilityLabel(tags.isEmpty ? nil : tags.map(\.name).joined(separator: ", "))
        }
    }

    /// The colours drawn, left to right.
    var dotColors: [TagColor] {
        Array(tags.map(\.color).filter { $0 != .none }.suffix(Self.maxDots))
    }

    var overflowText: String? {
        let coloured = tags.count { $0.color != .none }
        return coloured > Self.maxDots ? "+\(coloured - Self.maxDots)" : nil
    }

    static func color(for color: TagColor) -> NSColor {
        switch color {
        case .none: .secondaryLabelColor
        case .gray: .systemGray
        case .green: .systemGreen
        case .purple: .systemPurple
        case .blue: .systemBlue
        case .yellow: .systemYellow
        case .red: .systemRed
        case .orange: .systemOrange
        }
    }

    /// A 12 pt menu-item dot: filled with the tag's colour, or an outlined circle for no colour.
    static func menuImage(for color: TagColor, diameter: CGFloat = 12) -> NSImage {
        let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            if color == .none {
                NSColor.secondaryLabelColor.setStroke()
                path.lineWidth = 1
                path.stroke()
            } else {
                Self.color(for: color).setFill()
                path.fill()
            }
            return true
        }
        image.accessibilityDescription = nil
        return image
    }

    private static let overflowAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
        .foregroundColor: NSColor.secondaryLabelColor,
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) { fatalError("TagDotsView is created in code") }

    override var isFlipped: Bool { true }

    private var dotsWidth: CGFloat {
        let n = CGFloat(dotColors.count)
        return n == 0 ? 0 : Self.dotDiameter + (n - 1) * (Self.dotDiameter - Self.dotOverlap)
    }

    override var intrinsicContentSize: NSSize {
        var width = dotsWidth
        if let text = overflowText {
            width += 2 + (text as NSString).size(withAttributes: Self.overflowAttributes).width
        }
        return NSSize(width: ceil(width), height: NSView.noIntrinsicMetric)
    }

    override func draw(_ dirtyRect: NSRect) {
        let colors = dotColors
        guard !colors.isEmpty else { return }
        let y = (bounds.height - Self.dotDiameter) / 2
        var x: CGFloat = 0
        let ring = NSColor.controlBackgroundColor
        for color in colors {
            let rect = NSRect(x: x, y: y, width: Self.dotDiameter, height: Self.dotDiameter)
            let path = NSBezierPath(ovalIn: rect)
            Self.color(for: color).setFill()
            path.fill()
            ring.setStroke()           // separates overlapping dots, as Finder does
            path.lineWidth = 1
            path.stroke()
            x += Self.dotDiameter - Self.dotOverlap
        }
        if let text = overflowText {
            let size = (text as NSString).size(withAttributes: Self.overflowAttributes)
            (text as NSString).draw(at: NSPoint(x: dotsWidth + 2, y: (bounds.height - size.height) / 2),
                                    withAttributes: Self.overflowAttributes)
        }
    }
}
