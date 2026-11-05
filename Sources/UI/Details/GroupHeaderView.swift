import AppKit
import Core
import MacxFS

/// Group titles (spec §11): Core produces typed `GroupKey`s, UI formats them.
@MainActor
enum GroupTitles {
    static func title(for key: GroupKey) -> String {
        switch key {
        case .kind(let description, _): description
        case .date(let bucket): date(bucket)
        case .size(let bucket): size(bucket)
        case .letter(.digits): L10n.string("0–9")
        case .letter(.letter(let letter)): letter
        case .letter(.other): L10n.string("Other")
        }
    }

    private static func date(_ bucket: DateBucket) -> String {
        switch bucket {
        case .future: L10n.string("In the future")
        case .today: L10n.string("Today")
        case .yesterday: L10n.string("Yesterday")
        case .earlierThisWeek: L10n.string("Earlier this week")
        case .lastWeek: L10n.string("Last week")
        case .earlierThisMonth: L10n.string("Earlier this month")
        case .lastMonth: L10n.string("Last month")
        case .earlierThisYear: L10n.string("Earlier this year")
        case .longAgo: L10n.string("A long time ago")
        }
    }

    private static func size(_ bucket: SizeBucket) -> String {
        switch bucket {
        case .folders: L10n.string("Folders")
        case .empty: L10n.string("Empty (0 KB)")
        case .tiny: L10n.string("Tiny (0 – 16 KB)")
        case .small: L10n.string("Small (16 KB – 1 MB)")
        case .medium: L10n.string("Medium (1 – 128 MB)")
        case .large: L10n.string("Large (128 MB – 1 GB)")
        case .huge: L10n.string("Huge (1 – 4 GB)")
        case .gigantic: L10n.string("Gigantic (> 4 GB)")
        }
    }

    /// "1 item" / "%lld items".
    static func count(_ n: Int) -> String {
        n == 1 ? L10n.string("1 item") : String(format: L10n.string("%ld items"), n)
    }

    /// The header's accessibility value: "<title>, <n> items, collapsed|expanded".
    static func accessibilityValue(title: String, count: Int, collapsed: Bool) -> String {
        String(format: collapsed ? L10n.string("%@, %@, collapsed") : L10n.string("%@, %@, expanded"), title, Self.count(count))
    }
}

/// A floating group row of the Details list (P2-10): disclosure button, bold title, item count. It spans the
/// full row (the table asks for it with a nil column) and uses the items' fixed row height.
@MainActor
final class GroupHeaderView: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("macx.groupHeader")

    let disclosure = NSButton(title: "", target: nil, action: nil)
    let titleField = NSTextField(labelWithString: "")
    let countField = NSTextField(labelWithString: "")
    private(set) var groupIndex = 0
    var onToggle: ((Int) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.reuseID
        disclosure.bezelStyle = .disclosure
        disclosure.setButtonType(.pushOnPushOff)
        disclosure.title = ""
        disclosure.target = self
        disclosure.action = #selector(toggle(_:))
        disclosure.refusesFirstResponder = true
        titleField.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        titleField.lineBreakMode = .byTruncatingTail
        countField.font = CellStyle.font
        countField.textColor = .secondaryLabelColor
        countField.lineBreakMode = .byTruncatingTail
        textField = titleField
        let stack = NSStackView(views: [disclosure, titleField, countField])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        countField.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
    }

    required init?(coder: NSCoder) { fatalError("GroupHeaderView is created in code") }

    func configure(title: String, count: Int, collapsed: Bool, groupIndex: Int) {
        self.groupIndex = groupIndex
        if titleField.stringValue != title { titleField.stringValue = title }
        let countText = GroupTitles.count(count)
        if countField.stringValue != countText { countField.stringValue = countText }
        disclosure.state = collapsed ? .off : .on
        disclosure.setAccessibilityLabel(String(format: collapsed ? L10n.string("Expand %@") : L10n.string("Collapse %@"), title))
        setAccessibilityIdentifier(AXID.groupHeader(title))
        setAccessibilityLabel(title)
        setAccessibilityValue(GroupTitles.accessibilityValue(title: title, count: count, collapsed: collapsed))
    }

    @objc private func toggle(_ sender: Any?) { onToggle?(groupIndex) }
}
