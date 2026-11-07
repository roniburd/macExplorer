import AppKit
import Core
import MacxFS

/// The Filters ▾ popover (P3-10, spec §11): kind, date modified / created ranges, size range and extension.
/// Every control change reports the whole `SearchFilters` through `onChange`; `show(_:)` sets the controls quietly.
@MainActor
final class SearchFiltersView: NSViewController {
    var onChange: ((SearchFilters) -> Void)?

    private(set) var kindBoxes: [KindFilter: NSButton] = [:]
    let modifiedPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let createdPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let modifiedFrom = NSDatePicker(), modifiedTo = NSDatePicker()
    let createdFrom = NSDatePicker(), createdTo = NSDatePicker()
    let sizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let sizeMin = NSTextField(), sizeMax = NSTextField()
    let extensionField = NSTextField()
    let clearButton = NSButton(title: "", target: nil, action: nil)
    private var modifiedCustomRow: NSView?, createdCustomRow: NSView?, sizeCustomRow: NSView?
    private var filters = SearchFilters()
    private var quiet = false

    /// Popup item tags: 0 Any, 1…n the presets, -1 Custom….
    private static let customTag = -1
    private static var calendar: Calendar { Calendar.current }

    override func loadView() {
        let grid = NSGridView()
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.translatesAutoresizingMaskIntoConstraints = false

        let kinds = NSGridView()
        kinds.rowSpacing = 4
        kinds.columnSpacing = 12
        let all = KindFilter.allCases
        for start in stride(from: 0, to: all.count, by: 3) {
            let boxes = all[start..<min(start + 3, all.count)].map { kind -> NSView in
                let box = NSButton(checkboxWithTitle: SearchStrings.kind(kind), target: self, action: #selector(controlChanged(_:)))
                box.setAccessibilityLabel(SearchStrings.kind(kind))
                kindBoxes[kind] = box
                return box
            }
            kinds.addRow(with: boxes)
        }
        grid.addRow(with: [label(L10n.string("search.filters.kindLabel")), kinds])

        configureDatePopup(modifiedPopup, label: L10n.string("Date Modified"))
        configureDatePopup(createdPopup, label: L10n.string("Date Created"))
        grid.addRow(with: [label(L10n.string("search.filters.modifiedLabel")), modifiedPopup])
        let modifiedRow = dateRow(modifiedFrom, modifiedTo, label: L10n.string("Date Modified"))
        modifiedCustomRow = modifiedRow
        grid.addRow(with: [NSGridCell.emptyContentView, modifiedRow])
        grid.addRow(with: [label(L10n.string("search.filters.createdLabel")), createdPopup])
        let createdRow = dateRow(createdFrom, createdTo, label: L10n.string("Date Created"))
        createdCustomRow = createdRow
        grid.addRow(with: [NSGridCell.emptyContentView, createdRow])

        sizePopup.addItem(withTitle: L10n.string("Any"))
        sizePopup.lastItem?.tag = 0
        for (i, word) in SizeWord.allCases.enumerated() {
            sizePopup.addItem(withTitle: SearchStrings.size(word))
            sizePopup.lastItem?.tag = i + 1
        }
        sizePopup.addItem(withTitle: L10n.string("Custom…"))
        sizePopup.lastItem?.tag = Self.customTag
        sizePopup.target = self
        sizePopup.action = #selector(controlChanged(_:))
        sizePopup.setAccessibilityLabel(L10n.string("Size"))
        grid.addRow(with: [label(L10n.string("search.filters.sizeLabel")), sizePopup])
        for (field, placeholder) in [(sizeMin, L10n.string("Minimum, e.g. 10 MB")), (sizeMax, L10n.string("Maximum, e.g. 1 GB"))] {
            field.placeholderString = placeholder
            field.setAccessibilityLabel(placeholder)
            field.target = self
            field.action = #selector(controlChanged(_:))
            field.widthAnchor.constraint(equalToConstant: 130).isActive = true
        }
        let sizeRow = NSStackView(views: [sizeMin, NSTextField(labelWithString: "–"), sizeMax])
        sizeRow.spacing = 6
        sizeCustomRow = sizeRow
        grid.addRow(with: [NSGridCell.emptyContentView, sizeRow])

        extensionField.placeholderString = L10n.string("pdf, docx")
        extensionField.setAccessibilityLabel(L10n.string("Extension"))
        extensionField.target = self
        extensionField.action = #selector(controlChanged(_:))
        extensionField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        grid.addRow(with: [label(L10n.string("search.filters.extensionLabel")), extensionField])

        clearButton.title = SearchStrings.clearFilters
        clearButton.bezelStyle = .push
        clearButton.target = self
        clearButton.action = #selector(clearPressed(_:))
        grid.addRow(with: [NSGridCell.emptyContentView, clearButton])
        grid.column(at: 0).xPlacement = .trailing

        let root = NSView()
        root.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            grid.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            grid.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            grid.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])
        view = root
        applyFilters()
    }

    private func label(_ text: String) -> NSTextField { NSTextField(labelWithString: text) }

    private func configureDatePopup(_ popup: NSPopUpButton, label: String) {
        popup.addItem(withTitle: L10n.string("Any"))
        popup.lastItem?.tag = 0
        for (i, day) in RelativeDay.allCases.enumerated() {
            popup.addItem(withTitle: SearchStrings.day(day))
            popup.lastItem?.tag = i + 1
        }
        popup.addItem(withTitle: L10n.string("Custom…"))
        popup.lastItem?.tag = Self.customTag
        popup.target = self
        popup.action = #selector(controlChanged(_:))
        popup.setAccessibilityLabel(label)
    }

    private func dateRow(_ from: NSDatePicker, _ to: NSDatePicker, label: String) -> NSView {
        for (picker, name) in [(from, L10n.string("From")), (to, L10n.string("To"))] {
            picker.datePickerElements = .yearMonthDay
            picker.datePickerStyle = .textFieldAndStepper
            picker.dateValue = Date()
            picker.target = self
            picker.action = #selector(controlChanged(_:))
            picker.setAccessibilityLabel("\(label) \(name)")
        }
        let row = NSStackView(views: [from, NSTextField(labelWithString: "–"), to])
        row.spacing = 6
        return row
    }

    // MARK: state

    /// Sets the controls from `filters` without reporting a change.
    func show(_ filters: SearchFilters) {
        self.filters = filters
        guard isViewLoaded else { return }
        applyFilters()
    }

    private func applyFilters() {
        quiet = true
        defer { quiet = false }
        for (kind, box) in kindBoxes { box.state = filters.kinds.contains(kind) ? .on : .off }
        apply(filters.modified, popup: modifiedPopup, from: modifiedFrom, to: modifiedTo, row: modifiedCustomRow)
        apply(filters.created, popup: createdPopup, from: createdFrom, to: createdTo, row: createdCustomRow)
        if let size = filters.size {
            if let i = SizeWord.allCases.firstIndex(where: { $0.range == size }) {
                sizePopup.selectItem(withTag: i + 1)
            } else {
                sizePopup.selectItem(withTag: Self.customTag)
                sizeMin.stringValue = size.lower.map(String.init) ?? ""
                sizeMax.stringValue = size.upper.map { String($0 - 1) } ?? ""
            }
        } else {
            sizePopup.selectItem(withTag: 0)
        }
        sizeCustomRow?.isHidden = sizePopup.selectedTag() != Self.customTag
        extensionField.stringValue = filters.extensions.sorted().joined(separator: ", ")
    }

    private func apply(_ token: DateToken?, popup: NSPopUpButton, from: NSDatePicker, to: NSDatePicker, row: NSView?) {
        switch token {
        case nil: popup.selectItem(withTag: 0)
        case .relative(let day)?: popup.selectItem(withTag: (RelativeDay.allCases.firstIndex(of: day) ?? -2) + 1)
        case .days(let lower, let upper)?:
            popup.selectItem(withTag: Self.customTag)
            if let lower, let date = Self.date(lower.day) { from.dateValue = date }
            if let upper, let date = Self.date(upper.day) { to.dateValue = date }
        }
        row?.isHidden = popup.selectedTag() != Self.customTag
    }

    /// The filters the controls describe.
    func currentFilters() -> SearchFilters {
        var f = SearchFilters()
        f.kinds = Set(kindBoxes.filter { $0.value.state == .on }.map(\.key))
        f.modified = token(modifiedPopup, from: modifiedFrom, to: modifiedTo)
        f.created = token(createdPopup, from: createdFrom, to: createdTo)
        let sizeTag = sizePopup.selectedTag()
        if sizeTag > 0, SizeWord.allCases.indices.contains(sizeTag - 1) {
            f.size = SizeWord.allCases[sizeTag - 1].range
        } else if sizeTag == Self.customTag {
            f.size = Self.customSize(min: sizeMin.stringValue, max: sizeMax.stringValue)
        }
        f.extensions = Self.extensions(extensionField.stringValue)
        return f
    }

    private func token(_ popup: NSPopUpButton, from: NSDatePicker, to: NSDatePicker) -> DateToken? {
        let tag = popup.selectedTag()
        if tag > 0, RelativeDay.allCases.indices.contains(tag - 1) { return .relative(RelativeDay.allCases[tag - 1]) }
        guard tag == Self.customTag else { return nil }
        var a = from.dateValue, b = to.dateValue
        if a > b { swap(&a, &b) }
        return .days(lower: DayBound(day: Self.stamp(a), inclusive: true), upper: DayBound(day: Self.stamp(b), inclusive: true))
    }

    /// Min/max typed like the query syntax's sizes ("10 MB", "1.5GB", "500"); a blank side is open.
    static func customSize(min: String, max: String) -> ByteRange? {
        func bound(_ text: String, _ op: String) -> ByteRange? {
            let trimmed = text.replacingOccurrences(of: " ", with: "")
            guard !trimmed.isEmpty else { return nil }
            return QuerySyntax.parse("size:\(op)\(trimmed)").size
        }
        let lower = bound(min, ">="), upper = bound(max, "<=")
        switch (lower, upper) {
        case (nil, nil): return nil
        case (let l?, nil): return l
        case (nil, let u?): return u
        case (let l?, let u?): return l.intersection(u)
        }
    }

    /// Comma- or space-separated, normalised like `ext:` (lowercased, no dot).
    static func extensions(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" }).map {
            String($0.drop(while: { $0 == "." })).lowercased()
        }.filter { !$0.isEmpty })
    }

    private static func stamp(_ date: Date) -> DayStamp {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return DayStamp(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    private static func date(_ stamp: DayStamp) -> Date? {
        calendar.date(from: DateComponents(year: stamp.year, month: stamp.month, day: stamp.day))
    }

    // MARK: actions

    @objc private func controlChanged(_ sender: Any?) {
        guard !quiet else { return }
        modifiedCustomRow?.isHidden = modifiedPopup.selectedTag() != Self.customTag
        createdCustomRow?.isHidden = createdPopup.selectedTag() != Self.customTag
        sizeCustomRow?.isHidden = sizePopup.selectedTag() != Self.customTag
        let next = currentFilters()
        guard next != filters else { return }
        filters = next
        onChange?(next)
    }

    @objc private func clearPressed(_ sender: Any?) {
        filters = SearchFilters()
        applyFilters()
        onChange?(filters)
    }
}
