import AppKit
import Core

/// A toolbar button that also shows a history menu on long-press or right-click (§5.2 Back/Forward).
@MainActor
final class HistoryButton: NSButton {
    var historyMenu: (() -> NSMenu?)?
    private static let longPress: TimeInterval = 0.4

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, historyMenu != nil, let window else { return super.mouseDown(with: event) }
        highlight(true)
        let release = window.nextEvent(matching: [.leftMouseUp], until: Date(timeIntervalSinceNow: Self.longPress),
                                       inMode: .eventTracking, dequeue: true)
        highlight(false)
        if release != nil {
            sendAction(action, to: target)
        } else {
            showHistoryMenu()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard isEnabled, historyMenu != nil else { return super.rightMouseDown(with: event) }
        showHistoryMenu()
    }

    func showHistoryMenu() {
        guard let menu = historyMenu?(), !menu.items.isEmpty else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY + 2), in: self)
    }
}

/// ◀ ▶ ↑ as an NSToolbarItemGroup (§5.2). Enablement follows the session's history and folder.
@MainActor
final class NavigationButtons: NSObject {
    let backButton = HistoryButton()
    let forwardButton = HistoryButton()
    let upButton = HistoryButton()
    let group: NSToolbarItemGroup
    private let session: BrowserSession

    init(session: BrowserSession, identifier: NSToolbarItem.Identifier) {
        self.session = session
        group = NSToolbarItemGroup(itemIdentifier: identifier)
        super.init()
        let specs: [(HistoryButton, String, String, Selector)] = [
            (backButton, "chevron.backward", "Back", #selector(back(_:))),
            (forwardButton, "chevron.forward", "Forward", #selector(forward(_:))),
            (upButton, "arrow.up", "Up", #selector(up(_:))),
        ]
        group.subitems = specs.map { button, symbol, title, action in
            let label = L10n.string(title)
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.imagePosition = .imageOnly
            button.bezelStyle = .toolbar
            button.target = self
            button.action = action
            button.setAccessibilityLabel(label)
            button.toolTip = label
            let item = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier(identifier.rawValue + "." + title.lowercased()))
            item.view = button
            item.label = label
            item.toolTip = label
            return item
        }
        group.label = L10n.string("Navigation")
        group.controlRepresentation = .expanded
        backButton.historyMenu = { [weak self] in self?.backMenu() }
        forwardButton.historyMenu = { [weak self] in self?.forwardMenu() }
        update()
    }

    static func canGoUp(from url: URL) -> Bool { BreadcrumbPath.posixPath(url.standardizedFileURL) != "/" }

    func update() {
        backButton.isEnabled = session.history.canGoBack
        forwardButton.isEnabled = session.history.canGoForward
        upButton.isEnabled = Self.canGoUp(from: session.folder.directory)
    }

    /// Most recent first; choosing an item jumps there.
    func backMenu() -> NSMenu {
        let list = session.history.backList
        return menu(list.indices.reversed().map { ($0, list[$0]) }, action: #selector(jumpBack(_:)))
    }

    /// Next first.
    func forwardMenu() -> NSMenu {
        menu(Array(session.history.forwardList.enumerated()), action: #selector(jumpForward(_:)))
    }

    private func menu(_ entries: [(Int, URL)], action: Selector) -> NSMenu {
        let menu = NSMenu()
        for (index, url) in entries {
            let item: NSMenuItem
            if BrowserSession.isSearchURL(url) {            // a search entry (P3-10): its text, a magnifying glass
                let text = SearchSpec(url: url).map { SearchStrings.fieldPlaceholder($0.text.trimmingCharacters(in: .whitespaces)) }
                item = NSMenuItem(title: text ?? L10n.string("Search"), action: action, keyEquivalent: "")
                item.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
            } else {
                let name = url.lastPathComponent
                item = NSMenuItem(title: name.isEmpty || name == "/" ? "/" : name, action: action, keyEquivalent: "")
                item.toolTip = BreadcrumbPath.posixPath(url)
                item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            }
            item.target = self
            item.tag = index
            menu.addItem(item)
        }
        return menu
    }

    @objc private func back(_ sender: Any?) { session.goBack() }
    @objc private func forward(_ sender: Any?) { session.goForward() }
    @objc private func up(_ sender: Any?) { session.goUp() }
    @objc private func jumpBack(_ sender: NSMenuItem) { session.goBack(toIndex: sender.tag) }
    @objc private func jumpForward(_ sender: NSMenuItem) { session.goForward(toIndex: sender.tag) }
}
