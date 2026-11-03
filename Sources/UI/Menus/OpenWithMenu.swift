import AppKit
import Core
import MacxFS

/// Open With ▸ (§5.6): filled from LaunchServicesCache only. A miss shows "Loading…", and the menu updates in place
/// when the cache observer fires. It never blocks and does no LaunchServices lookups while the menu is built.
@MainActor
final class OpenWithMenu: NSObject, NSMenuDelegate {
    let menu: NSMenu
    private let files: [URL]
    private let typeIndex: UInt16
    private let cache: LaunchServicesCache
    private let icons: IconCache?
    private let openWith: @MainActor (URL) -> Void
    private let other: @MainActor () -> Void
    private let chooseDefault: @MainActor () -> Void
    private var token: ObserverToken?

    init(files: [URL], typeIndex: UInt16, cache: LaunchServicesCache, icons: IconCache?,
         openWith: @escaping @MainActor (URL) -> Void, other: @escaping @MainActor () -> Void,
         chooseDefault: @escaping @MainActor () -> Void) {
        self.menu = NSMenu(title: L10n.string("Open With"))
        self.files = files
        self.typeIndex = typeIndex
        self.cache = cache
        self.icons = icons
        self.openWith = openWith
        self.other = other
        self.chooseDefault = chooseDefault
        super.init()
        menu.delegate = self
        if let file = files.first { cache.prefetch(file: file, typeIndex: typeIndex) }
        token = cache.observe { [weak self] url in
            guard let self, url == self.files.first else { return }
            self.rebuild()
        }
        rebuild()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }

    func rebuild() {
        menu.removeAllItems()
        guard let file = files.first else { return }
        guard let apps = cache.cachedApplications(for: file, typeIndex: typeIndex),
              case .some(let defaultApp) = cache.cachedDefault(for: file) else {
            let loading = NSMenuItem(title: L10n.string("Loading…"), action: nil, keyEquivalent: "")
            loading.isEnabled = false
            menu.addItem(loading)
            addFooter()
            return
        }
        if let defaultApp {
            menu.addItem(appItem(defaultApp, isDefault: true))
            menu.addItem(.separator())
        }
        for app in apps where app.url != defaultApp?.url { menu.addItem(appItem(app, isDefault: false)) }
        addFooter()
    }

    private func appItem(_ app: AppInfo, isDefault: Bool) -> NSMenuItem {
        let openWith = self.openWith
        let item = ClosureMenuItem(title: isDefault ? String(format: L10n.string("%@ (default)"), app.name) : app.name) {
            openWith(app.url)
        }
        item.state = isDefault ? .on : .off
        icons?.fileIcon(for: app.url, rowID: .name(app.url.path), points: 16, scale: 2) { [weak item] image in
            item?.image = NSImage(cgImage: image, size: NSSize(width: 16, height: 16))
        }
        return item
    }

    private func addFooter() {
        menu.addItem(.separator())
        let other = self.other
        let chooseDefault = self.chooseDefault
        menu.addItem(ClosureMenuItem(title: L10n.string("Other…")) { other() })
        menu.addItem(ClosureMenuItem(title: L10n.string("Choose Default App…")) { chooseDefault() })
    }
}
