import AppKit
import Core
import MacxFS

/// The Tags ▸ submenu (P4-05): the first 7 known tags (most recently used first) with a coloured dot each, then
/// "Tags…". Built from `TagCache` and settings only (no file-system I/O); unknown entries count as not tagged and
/// are prefetched, and the states update in place while the menu is open.
@MainActor
enum TagMenu {
    static let shownTags = 7

    /// `editItem` replaces the default nil-targeted "Tags…" item (a context menu passes one bound to its target).
    static func build(for urls: [URL], cache: TagCache, settings: Core.Settings, editItem: NSMenuItem? = nil,
                      perform: @escaping @MainActor (TagEdit) -> Void) -> NSMenu {
        let menu = Menu(title: L10n.string("Tags"))
        let tags = Array(settings.knownTags.prefix(shownTags))
        for tag in tags {
            let item = ClosureMenuItem(title: tag.name) { perform(.toggle(tag)) }
            item.image = TagDotsView.menuImage(for: tag.color)
            item.identifier = NSUserInterfaceItemIdentifier("macx.menu.tag.\(tag.name)")
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let edit = editItem ?? {
            let item = NSMenuItem(title: L10n.string("Edit Tags…"), action: Selector(Command.editTags.selectorName), keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier("macx.menu.editTags")
            return item
        }()
        edit.title = L10n.string("Edit Tags…")
        menu.addItem(edit)
        let controller = Controller(urls: urls, tags: tags, cache: cache, menu: menu)
        menu.controller = controller
        menu.delegate = controller
        controller.updateStates()
        let missing = urls.filter { cache.cachedTags(for: $0) == nil }
        if !missing.isEmpty { cache.prefetch(missing) }
        return menu
    }

    /// `.on` when every URL's cached tags contain `tag`, `.mixed` when some do, `.off` otherwise (uncached → off).
    static func state(of tag: FileTag, urls: [URL], cache: TagCache) -> NSControl.StateValue {
        guard !urls.isEmpty else { return .off }
        let name = tag.name.lowercased()
        let having = urls.count { url in cache.cachedTags(for: url)?.contains { $0.name.lowercased() == name } ?? false }
        return having == urls.count ? .on : having > 0 ? .mixed : .off
    }

    /// Holds the delegate (NSMenu.delegate is weak).
    final class Menu: NSMenu {
        var controller: Controller?
    }

    @MainActor final class Controller: NSObject, NSMenuDelegate {
        let urls: [URL]
        let tags: [FileTag]
        let cache: TagCache
        weak var menu: NSMenu?
        private var token: ObserverToken?

        init(urls: [URL], tags: [FileTag], cache: TagCache, menu: NSMenu) {
            self.urls = urls; self.tags = tags; self.cache = cache; self.menu = menu
        }

        func updateStates() {
            guard let menu else { return }
            for (index, tag) in tags.enumerated() where index < menu.items.count {
                menu.items[index].state = TagMenu.state(of: tag, urls: urls, cache: cache)
            }
        }

        func menuWillOpen(_ menu: NSMenu) {
            let watched = Set(urls.map(\.standardizedFileURL))
            token = cache.observe { [weak self] changed in
                guard let self, changed.contains(where: { watched.contains($0.standardizedFileURL) }) else { return }
                self.updateStates()
            }
            updateStates()     // values that arrived between build and open
        }

        func menuDidClose(_ menu: NSMenu) {
            token?.cancel()
            token = nil
        }
    }
}
