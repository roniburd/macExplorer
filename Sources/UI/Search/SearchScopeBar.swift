import AppKit
import Core
import MacxFS

/// The bar under the toolbar while searching (P3-10, spec §11): scope chips (This Folder / Subfolders / This Mac),
/// Name / Contents, Filters ▾ (a popover with SearchFiltersView), progress and status, Stop, Save Search…, and a
/// notice line (diagnostics first, then plan and results notices).
@MainActor
final class SearchScopeBar: NSView {
    let scopeControl: NSSegmentedControl
    let modeControl: NSSegmentedControl
    let filtersButton = NSButton(title: "", target: nil, action: nil)
    let spinner = NSProgressIndicator()
    let statusLabel = NSTextField(labelWithString: "")
    let stopButton = NSButton(title: "", target: nil, action: nil)
    let saveButton = NSButton(title: "", target: nil, action: nil)
    let noticeLabel = NSTextField(labelWithString: "")
    private let filtersBadge = NSView()
    private let row = NSStackView()
    private var popover: NSPopover?
    private var filtersController: SearchFiltersView?

    /// Wired by ContentViewController.
    var onScope: ((SearchScope) -> Void)?
    var onMode: ((SearchMode) -> Void)?
    var onFilters: ((SearchFilters) -> Void)?
    var onStop: (() -> Void)?
    var onSave: (() -> Void)?
    private var currentFilters = SearchFilters()

    static let scopes: [SearchScope] = [.thisFolder, .subfolders, .thisMac]
    static let modes: [SearchMode] = [.name, .contents]

    override init(frame frameRect: NSRect) {
        scopeControl = NSSegmentedControl(labels: Self.scopes.map(SearchStrings.scope), trackingMode: .selectOne, target: nil, action: nil)
        modeControl = NSSegmentedControl(labels: Self.modes.map(SearchStrings.mode), trackingMode: .selectOne, target: nil, action: nil)
        super.init(frame: frameRect)
        setAccessibilityIdentifier(AXID.searchScopeBar)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(L10n.string("Search Options"))
        build()
    }

    required init?(coder: NSCoder) { fatalError("created in code") }

    private func build() {
        for (control, id, label) in [(scopeControl, AXID.searchScope, L10n.string("Search Scope")),
                                     (modeControl, AXID.searchMode, L10n.string("Search Names or Contents"))] {
            control.controlSize = .small
            control.segmentStyle = .rounded
            control.setAccessibilityIdentifier(id)
            control.setAccessibilityLabel(label)
            control.target = self
        }
        scopeControl.action = #selector(scopeChanged(_:))
        modeControl.action = #selector(modeChanged(_:))
        filtersButton.title = SearchStrings.filters
        filtersButton.image = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle", accessibilityDescription: nil)
        filtersButton.imagePosition = .imageLeading
        configure(filtersButton, id: AXID.searchFilters, action: #selector(showFilters(_:)))
        filtersBadge.wantsLayer = true
        filtersBadge.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        filtersBadge.layer?.cornerRadius = 3
        filtersBadge.isHidden = true
        filtersBadge.translatesAutoresizingMaskIntoConstraints = false
        filtersButton.addSubview(filtersBadge)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setAccessibilityIdentifier(AXID.searchStatus)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stopButton.title = SearchStrings.stop
        configure(stopButton, id: AXID.searchStop, action: #selector(stopPressed(_:)))
        saveButton.title = SearchStrings.save
        configure(saveButton, id: AXID.searchSave, action: #selector(savePressed(_:)))
        noticeLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        noticeLabel.textColor = .secondaryLabelColor
        noticeLabel.lineBreakMode = .byTruncatingTail
        noticeLabel.setAccessibilityIdentifier(AXID.searchNotice)
        noticeLabel.isHidden = true
        noticeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        for view in [scopeControl, modeControl, filtersButton, spinner, statusLabel, spacer, stopButton, saveButton] as [NSView] {
            row.addArrangedSubview(view)
        }
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        let column = NSStackView(views: [row, noticeLabel])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            column.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4),
            row.widthAnchor.constraint(equalTo: column.widthAnchor),
            filtersBadge.widthAnchor.constraint(equalToConstant: 6),
            filtersBadge.heightAnchor.constraint(equalToConstant: 6),
            filtersBadge.topAnchor.constraint(equalTo: filtersButton.topAnchor, constant: 1),
            filtersBadge.trailingAnchor.constraint(equalTo: filtersButton.trailingAnchor, constant: -1),
        ])
    }

    private func configure(_ button: NSButton, id: String, action: Selector) {
        button.bezelStyle = .accessoryBarAction
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.target = self
        button.action = action
        button.setAccessibilityIdentifier(id)
        button.setAccessibilityLabel(button.title)
    }

    /// The height the bar wants: one row, plus the notice line when it shows.
    var preferredHeight: CGFloat { noticeLabel.isHidden ? 30 : 46 }

    /// Refreshes every control from the field controller and the session.
    func update(controller: SearchController, session: BrowserSession) {
        scopeControl.selectedSegment = Self.scopes.firstIndex(of: controller.scope) ?? 0
        modeControl.selectedSegment = Self.modes.firstIndex(of: controller.mode) ?? 0
        currentFilters = controller.filters
        filtersBadge.isHidden = controller.filters.isEmpty
        filtersButton.setAccessibilityValue(controller.filters.isEmpty ? nil : L10n.string("Filters on"))
        filtersController?.show(controller.filters)
        let results = session.results
        let searching: Bool = if case .searching? = results?.state { true } else { false }
        if searching { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        stopButton.isHidden = !searching
        statusLabel.stringValue = results.flatMap { SearchStrings.status($0.state) } ?? ""
        saveButton.isEnabled = session.searchSpec != nil
        var lines = controller.diagnostics.map(SearchStrings.diagnostic)
        let notices = results?.notices ?? session.lastPlan?.notices ?? []
        lines += notices.map(SearchStrings.notice)
        noticeLabel.stringValue = lines.joined(separator: "  ·  ")
        noticeLabel.isHidden = lines.isEmpty
        noticeLabel.toolTip = lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    var noticeText: String? { noticeLabel.isHidden ? nil : noticeLabel.stringValue }

    // MARK: actions

    @objc private func scopeChanged(_ sender: Any?) {
        let i = scopeControl.selectedSegment
        if Self.scopes.indices.contains(i) { onScope?(Self.scopes[i]) }
    }

    @objc private func modeChanged(_ sender: Any?) {
        let i = modeControl.selectedSegment
        if Self.modes.indices.contains(i) { onMode?(Self.modes[i]) }
    }

    @objc private func stopPressed(_ sender: Any?) { onStop?() }
    @objc private func savePressed(_ sender: Any?) { onSave?() }

    @objc func showFilters(_ sender: Any?) {
        if let popover, popover.isShown { popover.performClose(nil); return }
        let controller = filtersController ?? SearchFiltersView()
        filtersController = controller
        controller.onChange = { [weak self] filters in self?.onFilters?(filters) }
        controller.show(currentFilters)
        let popover = self.popover ?? NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        self.popover = popover
        popover.show(relativeTo: filtersButton.bounds, of: filtersButton, preferredEdge: .maxY)
    }
}
