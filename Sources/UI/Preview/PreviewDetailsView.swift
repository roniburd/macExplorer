import AppKit
import Core

/// The details summary under a preview (§11: "size, dates, dimensions or duration from `MDItem`"): label/value rows,
/// absent values hidden.
@MainActor
final class PreviewDetailsView: NSView {
    enum Row: Int, CaseIterable { case kind, size, created, modified, dimensions, duration, pages }

    private let grid = NSGridView()
    private var values: [Row: NSTextField] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier(AXID.previewDetails)
        setAccessibilityLabel(L10n.string("preview.details"))
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 4
        grid.columnSpacing = 8
        for row in Row.allCases {
            let label = NSTextField(labelWithString: Self.label(row))
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            let value = NSTextField(labelWithString: "")
            value.isSelectable = true
            value.lineBreakMode = .byTruncatingMiddle
            value.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            value.setAccessibilityLabel(Self.label(row))
            grid.addRow(with: [label, value])
            values[row] = value
        }
        grid.column(at: 0).xPlacement = .trailing
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            grid.topAnchor.constraint(equalTo: topAnchor),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("PreviewDetailsView is created in code") }

    static func label(_ row: Row) -> String {
        switch row {
        case .kind: L10n.string("preview.details.kind")
        case .size: L10n.string("preview.details.size")
        case .created: L10n.string("preview.details.created")
        case .modified: L10n.string("preview.details.modified")
        case .dimensions: L10n.string("preview.details.dimensions")
        case .duration: L10n.string("preview.details.duration")
        case .pages: L10n.string("preview.details.pages")
        }
    }

    /// Positional, like the Finder and media players: "0:05", "12:34", "1:02:03".
    static func duration(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return nil }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// The text of each row for `d`; nil = the row is hidden.
    static func values(_ d: PreviewDetails) -> [Row: String] {
        var out: [Row: String] = [:]
        if !d.kindDescription.isEmpty { out[.kind] = d.kindDescription }
        if let size = d.size { out[.size] = Formatters.bytes(size) }
        if let created = d.created { out[.created] = Formatters.date(created, style: .absolute) }
        if let modified = d.modified { out[.modified] = Formatters.date(modified, style: .absolute) }
        if let w = d.pixelWidth, let h = d.pixelHeight { out[.dimensions] = String(format: L10n.string("preview.details.dimensionsValue"), w, h) }
        if let text = d.duration.flatMap(duration) { out[.duration] = text }
        if let pages = d.pageCount { out[.pages] = NumberFormatter.localizedString(from: NSNumber(value: pages), number: .decimal) }
        return out
    }

    func show(_ d: PreviewDetails) {
        let texts = Self.values(d)
        for row in Row.allCases {
            let text = texts[row]
            values[row]?.stringValue = text ?? ""
            grid.row(at: row.rawValue).isHidden = text == nil
        }
    }

    /// Visible rows' values, in order (tests, scenario probes).
    var visibleValues: [String] {
        Row.allCases.compactMap { grid.row(at: $0.rawValue).isHidden ? nil : values[$0]?.stringValue }
    }
}
