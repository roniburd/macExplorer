import AppKit
import Core
import MacxFS

/// A menu item that runs a closure (sidebar row menus).
@MainActor
final class SidebarMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire(_:)), keyEquivalent: "")
        target = self
        isEnabled = enabled
    }

    required init(coder: NSCoder) { fatalError("created in code") }

    @objc private func fire(_ sender: Any?) { handler() }
}

extension SidebarViewController {
    /// Right-click menus (§5.4). Favorites: Open in New Window, Remove from Favorites (+ Locate… when stale).
    /// Locations and tree volume roots: Open in New Window, Eject, Properties. Tree folders: Open in New Window.
    /// Items act on the clicked row, not the selection.
    func menu(forRow row: Int) -> NSMenu? {
        guard let item = item(atRow: row), !item.isHeader else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let url = item.url {
            menu.addItem(SidebarMenuItem(L10n.string("Open in New Window")) { [weak self] in
                self?.context.windows.openWindow(at: url)
            })
        }
        switch item {
        case .favorite(let favorite):
            menu.addItem(.separator())
            if favorite.isStale && favorite.defaultKind == nil {
                menu.addItem(SidebarMenuItem(L10n.string("Locate…")) { [weak self] in self?.locate(favorite) })
            }
            menu.addItem(SidebarMenuItem(L10n.string("Remove from Favorites")) { [weak self] in
                self?.perform(.removeFromFavorites, on: item)
            })
        case .location(let volume):
            addVolumeItems(volume, item: item, to: menu)
        case .folder(let node) where node.isVolumeRoot:
            addVolumeItems(node.volume, item: item, to: menu)
        case .iCloudDrive, .folder, .favoritesHeader, .locationsHeader, .foldersHeader:
            break
        }
        return menu.items.isEmpty ? nil : menu
    }

    private func addVolumeItems(_ volume: VolumeInfo, item: SidebarItem, to menu: NSMenu) {
        if volume.isEjectable {
            menu.addItem(SidebarMenuItem(L10n.string("Eject")) { [weak self] in self?.eject(volume) })
        }
        let canShowProperties = item.commandTarget.map { handler?.canPerform(.properties, target: $0) ?? false } ?? false
        menu.addItem(SidebarMenuItem(L10n.string("Properties"), enabled: canShowProperties) { [weak self] in
            self?.perform(.properties, on: item)
        })
    }

    /// Runs `command` on `item`'s target through the handler (row menus act on the clicked row).
    func perform(_ command: Command, on item: SidebarItem) {
        guard let target = item.commandTarget else { return }
        handler?.perform(command, target: target, sender: nil)
    }
}
