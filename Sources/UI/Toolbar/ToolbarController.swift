import AppKit
import Core
import MacxFS

/// The browser window's NSToolbar delegate (§5.2): ◀ ▶ ↑ group, address bar (flexible), filter field, Details/Icons
/// switcher. Keeps them in sync with the session (folder, history, view mode) and the volume list.
@MainActor
final class ToolbarController: NSObject, NSToolbarDelegate {
    static let navigationID = NSToolbarItem.Identifier("macx.toolbar.navigation")
    static let addressID = NSToolbarItem.Identifier("macx.toolbar.address")
    static let searchID = NSToolbarItem.Identifier("macx.toolbar.search")
    static let viewSwitcherID = NSToolbarItem.Identifier("macx.toolbar.viewSwitcher")

    let navigation: NavigationButtons
    let addressBar: AddressBarView
    let search: SearchFieldController
    let viewSwitcher: NSToolbarItemGroup
    let searchItem: NSSearchToolbarItem
    let addressItem: NSToolbarItem

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
        let modes = ViewMode.allCases
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

    /// The Details/Icons switcher (segment `index` of ViewMode.allCases).
    func selectViewMode(at index: Int) {
        let modes = ViewMode.allCases
        guard modes.indices.contains(index) else { return }
        session.viewMode = modes[index]
        context.environment.settings.viewMode = modes[index]
        syncViewMode()
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.navigationID, Self.addressID, Self.searchID, Self.viewSwitcherID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.navigationID: navigation.group
        case Self.addressID: addressItem
        case Self.searchID: searchItem
        case Self.viewSwitcherID: viewSwitcher
        default: nil
        }
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
        case .banner:
            break
        }
    }

    private func showFolder() {
        let directory = session.folder.directory
        addressBar.show(directory, volume: context.environment.volumes.volume(for: directory))
    }

    private func syncViewMode() {
        viewSwitcher.selectedIndex = ViewMode.allCases.firstIndex(of: session.viewMode) ?? 0
    }

    @objc private func viewSwitcherChanged(_ sender: Any?) {
        selectViewMode(at: viewSwitcher.selectedIndex)
    }

    private static func symbol(for mode: ViewMode) -> String {
        switch mode {
        case .details: "list.bullet"
        case .icons: "square.grid.2x2"
        }
    }

    private static func title(for mode: ViewMode) -> String {
        switch mode {
        case .details: L10n.string("Details")
        case .icons: L10n.string("Icons")
        }
    }
}
