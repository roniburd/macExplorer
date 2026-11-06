import AppKit
import Core
import MacxFS

/// The browser window's NSToolbar delegate (§5.2): ◀ ▶ ↑ group, address bar (flexible), filter field, Details/Icons
/// switcher, the New Tab button (P2-06), the Send Feedback menu, and the update badge (hidden unless an update needs attention). Keeps them in sync with the session
/// (folder, history, view mode) and the volume list.
@MainActor
final class ToolbarController: NSObject, NSToolbarDelegate {
    static let navigationID = NSToolbarItem.Identifier("macx.toolbar.navigation")
    static let addressID = NSToolbarItem.Identifier("macx.toolbar.address")
    static let searchID = NSToolbarItem.Identifier("macx.toolbar.search")
    static let viewSwitcherID = NSToolbarItem.Identifier("macx.toolbar.viewSwitcher")
    static let feedbackID = NSToolbarItem.Identifier("macx.toolbar.feedback")
    static let updateID = NSToolbarItem.Identifier("macx.toolbar.update")
    /// New Tab (P2-06): click = ⌘T, drop folders = tabs (the native tab bar has no drop API).
    static let newTabID = NSToolbarItem.Identifier(AXID.newTabItem)

    let navigation: NavigationButtons
    let addressBar: AddressBarView
    let search: SearchFieldController
    let viewSwitcher: NSToolbarItemGroup
    let searchItem: NSSearchToolbarItem
    let addressItem: NSToolbarItem
    let feedbackItem: NSMenuToolbarItem
    let updateItem: UpdateBadgeItem
    let newTabItem = NewTabToolbarItem()

    private let context: UIContext
    private let session: BrowserSession
    private var sessionToken: ObserverToken?
    private var volumesToken: ObserverToken?

    init(context: UIContext, session: BrowserSession) {
        self.context = context
        self.session = session
        navigation = NavigationButtons(session: session, identifier: Self.navigationID)
        addressBar = AddressBarView(context: context)
        search = SearchFieldController(session: session)
        searchItem = NSSearchToolbarItem(itemIdentifier: Self.searchID)
        addressItem = NSToolbarItem(itemIdentifier: Self.addressID)
        feedbackItem = NSMenuToolbarItem(itemIdentifier: Self.feedbackID)
        updateItem = UpdateBadgeItem(model: context.updates)
        let modes = Self.switcherModes
        viewSwitcher = NSToolbarItemGroup(
            itemIdentifier: Self.viewSwitcherID,
            images: modes.map { NSImage(systemSymbolName: Self.symbol(for: $0), accessibilityDescription: Self.title(for: $0)) ?? NSImage() },
            selectionMode: .selectOne, labels: modes.map(Self.title(for:)), target: nil, action: nil)
        super.init()

        searchItem.searchField = search.field
        searchItem.label = L10n.string("Filter")
        addressItem.view = addressBar
        addressItem.label = L10n.string("Address")
        addressItem.visibilityPriority = .high
        feedbackItem.menu = FeedbackActions.menu()
        feedbackItem.image = NSImage(systemSymbolName: "bubble.left", accessibilityDescription: L10n.string("Send Feedback"))
        feedbackItem.label = L10n.string("Send Feedback")
        feedbackItem.toolTip = L10n.string("Send Feedback")
        feedbackItem.showsIndicator = false
        viewSwitcher.target = self
        viewSwitcher.action = #selector(viewSwitcherChanged(_:))
        viewSwitcher.label = L10n.string("View")
        viewSwitcher.controlRepresentation = .expanded
        for (item, mode) in zip(viewSwitcher.subitems, modes) {
            item.label = Self.title(for: mode)
            item.toolTip = Self.title(for: mode)
        }
        addressBar.onNavigate = { [weak session] url, name in session?.navigate(to: url, selecting: name) }

        sessionToken = session.observe { [weak self] event in self?.handle(event) }
        volumesToken = context.environment.volumes.observe { [weak self] _ in self?.showFolder() }
        showFolder()
        syncViewMode()
    }

    /// ⌘F / F3: the filter field takes the keyboard.
    func beginSearch() {
        searchItem.beginSearchInteraction()
        if let window = search.field.window, search.field.currentEditor() == nil {
            window.makeFirstResponder(search.field)
        }
    }

    /// The view modes the toolbar switcher offers, in segment order.
    static let switcherModes: [ViewMode] = [.details, .icons, .columns]

    /// The Details/Icons/Columns switcher (segment `index` of `switcherModes`).
    func selectViewMode(at index: Int) {
        let modes = Self.switcherModes
        guard modes.indices.contains(index) else { return }
        session.updateViewState { $0.mode = modes[index] }   // this folder only (P2-08)
        syncViewMode()
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.navigationID, Self.addressID, Self.searchID, Self.viewSwitcherID, Self.newTabID, Self.feedbackID, Self.updateID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space, .flexibleSpace]
    }

    /// The badge is the only place "Restart to Update" and the manual-check feedback appear (spec §3.1–3.2): the user
    /// cannot drag it out via Customize Toolbar… (review of Task 8).
    func toolbarImmovableItemIdentifiers(_ toolbar: NSToolbar) -> Set<NSToolbarItem.Identifier> { [Self.updateID] }

    func toolbar(_ toolbar: NSToolbar, itemIdentifier: NSToolbarItem.Identifier, canBeInsertedAt index: Int) -> Bool {
        itemIdentifier != Self.updateID || index != NSNotFound
    }

    /// An autosaved configuration from an older build (or one the user customized before these items existed) is
    /// restored as is and never gains new default items. The badge is put back at the trailing edge whenever it is
    /// missing (review of Task 8). The Send Feedback menu is movable, so it is added just before the badge only once
    /// (`Settings.toolbarFeedbackItemOffered`); a user who removes it afterwards keeps it removed (review of Task 10).
    func ensureDefaultItems(in toolbar: NSToolbar) {
        if !toolbar.items.contains(where: { $0.itemIdentifier == Self.updateID }) {
            toolbar.insertItem(withItemIdentifier: Self.updateID, at: toolbar.items.count)
        }
        let settings = context.environment.settings
        if !settings.toolbarNewTabItemOffered {
            // New Tab (P2-06) is offered once, like Send Feedback: after the view switcher, else before the badge.
            settings.toolbarNewTabItemOffered = true
            if !toolbar.items.contains(where: { $0.itemIdentifier == Self.newTabID }) {
                let index = toolbar.items.firstIndex { $0.itemIdentifier == Self.viewSwitcherID }.map { $0 + 1 }
                    ?? toolbar.items.firstIndex { $0.itemIdentifier == Self.updateID } ?? toolbar.items.count
                toolbar.insertItem(withItemIdentifier: Self.newTabID, at: index)
            }
        }
        guard !settings.toolbarFeedbackItemOffered else { return }
        settings.toolbarFeedbackItemOffered = true
        guard !toolbar.items.contains(where: { $0.itemIdentifier == Self.feedbackID }) else { return }
        let badge = toolbar.items.firstIndex { $0.itemIdentifier == Self.updateID } ?? toolbar.items.count
        toolbar.insertItem(withItemIdentifier: Self.feedbackID, at: badge)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        // Customize Toolbar… asks for palette copies: never hand out the live items (their views would move).
        guard flag else { return Self.paletteItem(for: itemIdentifier) }
        return switch itemIdentifier {
        case Self.navigationID: navigation.group
        case Self.addressID: addressItem
        case Self.searchID: searchItem
        case Self.viewSwitcherID: viewSwitcher
        case Self.feedbackID: feedbackItem
        case Self.updateID: updateItem
        case Self.newTabID: newTabItem
        default: nil
        }
    }

    /// A view-less stand-in (label and symbol) for the customization palette.
    static func paletteItem(for identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        let spec: (label: String, symbol: String)
        switch identifier {
        case navigationID: spec = (L10n.string("Navigation"), "chevron.left.chevron.right")
        case addressID: spec = (L10n.string("Address"), "link")
        case searchID: spec = (L10n.string("Filter"), "magnifyingglass")
        case viewSwitcherID: spec = (L10n.string("View"), "list.bullet")
        case feedbackID: spec = (L10n.string("Send Feedback"), "bubble.left")
        case updateID: spec = (L10n.string("Update"), "arrow.down.circle")
        case newTabID: spec = (L10n.string("New Tab"), "plus.square.on.square")
        default: return nil
        }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = spec.label
        item.paletteLabel = spec.label
        item.image = NSImage(systemSymbolName: spec.symbol, accessibilityDescription: spec.label)
        return item
    }

    // MARK: private

    private func handle(_ event: SessionEvent) {
        switch event {
        case .folderChanged:
            showFolder()
            search.folderChanged()
            navigation.update()
        case .historyChanged:
            navigation.update()
        case .viewModeChanged:
            syncViewMode()
        case .banner, .viewStateChanged, .columnsChanged:
            break
        }
    }

    private func showFolder() {
        let directory = session.folder.directory
        addressBar.show(directory, volume: context.environment.volumes.volume(for: directory))
    }

    private func syncViewMode() {
        viewSwitcher.selectedIndex = Self.switcherModes.firstIndex(of: session.viewMode) ?? 0
    }

    @objc private func viewSwitcherChanged(_ sender: Any?) {
        selectViewMode(at: viewSwitcher.selectedIndex)
    }

    private static func symbol(for mode: ViewMode) -> String {
        switch mode {
        case .details: "list.bullet"
        case .icons: "square.grid.2x2"
        case .columns: "rectangle.split.3x1"
        }
    }

    private static func title(for mode: ViewMode) -> String {
        switch mode {
        case .details: L10n.string("Details")
        case .icons: L10n.string("Icons")
        case .columns: L10n.string("Columns")
        }
    }
}
