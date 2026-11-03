import AppKit
import Core
import MacxFS

/// One clickable breadcrumb segment. P1-36 adds its drop forwarding (segments accept drops, §5.6).
@MainActor
final class BreadcrumbSegmentButton: NSButton {
    var segmentURL: URL?
}

/// Breadcrumb mode of the address bar (§5.2): `Volume › a › b`. Clicking a segment navigates; the › after a segment
/// opens a menu of that folder's subfolders; leading segments that don't fit collapse into a « menu; a click on empty
/// space asks for edit mode. Lays out with frames (cheap; rebuilt on every navigation).
@MainActor
final class BreadcrumbView: NSView {
    var onNavigate: ((URL) -> Void)?
    var onEmptySpaceClick: (() -> Void)?
    /// Lists a folder's subfolders off main for the › menus (installed by AddressBarView).
    var listSubfolders: ((URL) async -> [String])?

    private(set) var segments: [BreadcrumbSegment] = []
    private(set) var segmentButtons: [BreadcrumbSegmentButton] = []
    private(set) var chevronButtons: [NSButton] = []
    let overflowButton = NSButton()
    private(set) var collapsedCount = 0

    private static let spacing: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        overflowButton.title = "«"
        overflowButton.bezelStyle = .accessoryBarAction
        overflowButton.showsBorderOnlyWhileMouseInside = true
        overflowButton.target = self
        overflowButton.action = #selector(overflowClicked(_:))
        overflowButton.setAccessibilityLabel(L10n.string("Show Enclosing Folders"))
        overflowButton.isHidden = true
        addSubview(overflowButton)
    }

    required init?(coder: NSCoder) { fatalError("created in code") }

    override var isFlipped: Bool { true }

    /// Replaces the segments (one button + one › per segment).
    func show(_ segments: [BreadcrumbSegment]) {
        guard segments != self.segments else { return }
        self.segments = segments
        for button in segmentButtons { button.removeFromSuperview() }
        for button in chevronButtons { button.removeFromSuperview() }
        segmentButtons = segments.enumerated().map { index, segment in makeSegmentButton(segment, index: index) }
        chevronButtons = segments.enumerated().map { index, segment in makeChevron(segment, index: index) }
        for (segment, chevron) in zip(segmentButtons, chevronButtons) {
            addSubview(segment)
            addSubview(chevron)
        }
        needsLayout = true
    }

    /// The text the address bar shows in breadcrumb mode (scenario hook).
    var displayText: String { segments.map(\.title).joined(separator: " › ") }

    // MARK: layout

    override func layout() {
        super.layout()
        let height = bounds.height
        let widths = segmentButtons.map { ceil($0.fittingSize.width) }
        let chevronWidth = chevronButtons.first.map { ceil($0.fittingSize.width) } ?? 0
        let overflowWidth = ceil(overflowButton.fittingSize.width)
        collapsedCount = BreadcrumbPath.collapsedCount(segmentWidths: widths, chevronWidth: chevronWidth,
                                                       overflowWidth: overflowWidth, available: bounds.width)
        var x: CGFloat = 0
        func place(_ view: NSView, width: CGFloat) {
            let h = min(height, max(view.fittingSize.height, 22))
            view.frame = NSRect(x: x, y: floor((height - h) / 2), width: width, height: h)
            x += width + Self.spacing
        }
        overflowButton.isHidden = collapsedCount == 0
        if collapsedCount > 0 { place(overflowButton, width: overflowWidth) }
        for index in segmentButtons.indices {
            let hidden = index < collapsedCount
            segmentButtons[index].isHidden = hidden
            chevronButtons[index].isHidden = hidden
            guard !hidden else { continue }
            let room = max(0, bounds.width - x - chevronWidth)
            place(segmentButtons[index], width: min(widths[index], room))
            place(chevronButtons[index], width: chevronWidth)
        }
    }

    // MARK: clicks

    override func mouseDown(with event: NSEvent) {
        // Buttons take their own clicks; anything reaching here is empty space.
        emptySpaceClicked()
    }

    func emptySpaceClicked() { onEmptySpaceClick?() }

    @objc private func segmentClicked(_ sender: BreadcrumbSegmentButton) {
        if let url = sender.segmentURL { onNavigate?(url) }
    }

    @objc func menuItemChosen(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { onNavigate?(url) }
    }

    @objc private func overflowClicked(_ sender: NSButton) {
        let menu = overflowMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 2), in: sender)
    }

    @objc private func chevronClicked(_ sender: NSButton) {
        guard segments.indices.contains(sender.tag) else { return }
        let folder = segments[sender.tag].url
        Task { @MainActor [weak self, weak sender] in
            let names = await self?.listSubfolders?(folder) ?? []
            guard let self, let sender, sender.window != nil, self.segments.indices.contains(sender.tag),
                  self.segments[sender.tag].url == folder else { return }
            let menu = Self.subfolderMenu(names: names, in: folder, target: self)
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 2), in: sender)
        }
    }

    /// The « menu: the collapsed leading segments, root first.
    func overflowMenu() -> NSMenu {
        let menu = NSMenu()
        for segment in segments.prefix(collapsedCount) {
            menu.addItem(Self.folderItem(title: segment.title, url: segment.url, target: self,
                                         symbol: segment.symbolName ?? "folder"))
        }
        return menu
    }

    /// A › menu: one item per subfolder (navigates), or a disabled "No Subfolders" item.
    static func subfolderMenu(names: [String], in folder: URL, target: BreadcrumbView) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        guard !names.isEmpty else {
            let item = NSMenuItem(title: L10n.string("No Subfolders"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return menu
        }
        for name in names {
            menu.addItem(folderItem(title: name, url: folder.appending(path: name, directoryHint: .isDirectory),
                                    target: target, symbol: "folder"))
        }
        return menu
    }

    private static func folderItem(title: String, url: URL, target: BreadcrumbView, symbol: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(menuItemChosen(_:)), keyEquivalent: "")
        item.target = target
        item.representedObject = url
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    // MARK: building

    private func makeSegmentButton(_ segment: BreadcrumbSegment, index: Int) -> BreadcrumbSegmentButton {
        let button = BreadcrumbSegmentButton(title: segment.title, target: self, action: #selector(segmentClicked(_:)))
        button.segmentURL = segment.url
        button.bezelStyle = .accessoryBarAction
        button.showsBorderOnlyWhileMouseInside = true
        button.lineBreakMode = .byTruncatingMiddle
        button.setAccessibilityIdentifier(AXID.breadcrumbSegment(index))
        button.toolTip = BreadcrumbPath.posixPath(segment.url)
        if let symbol = segment.symbolName {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.imagePosition = .imageLeading
        }
        return button
    }

    private func makeChevron(_ segment: BreadcrumbSegment, index: Int) -> NSButton {
        let chevron = NSButton(title: "›", target: self, action: #selector(chevronClicked(_:)))
        chevron.tag = index
        chevron.bezelStyle = .accessoryBarAction
        chevron.showsBorderOnlyWhileMouseInside = true
        chevron.setAccessibilityLabel(String(format: L10n.string("Subfolders of '%@'"), segment.title))
        return chevron
    }
}
