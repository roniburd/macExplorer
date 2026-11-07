// Sources/UI/QuickLook/QuickLookController.swift
import AppKit
import Quartz
import Core
import MacxFS

/// The shared Quick Look panel as QuickLookController sees it (tests use an in-memory fake).
@MainActor protocol QuickLookPanelControlling: AnyObject {
    /// The shared panel is on screen (any window or tab may have opened it): Space and Esc close it.
    var isVisible: Bool { get }
    /// On screen with this window's bridge as its data source: only then are selection changes worth items.
    var isControlling: Bool { get }
    func show()
    func hide()
    func reloadData()
}

/// QLPreviewPanel.shared(). Our process makes no file-system calls for Quick Look: the panel receives URLs from the
/// model, and the out-of-process previewer reads the file (a user-initiated open, like a double-click).
@MainActor
final class SystemQuickLookPanel: QuickLookPanelControlling {
    /// The window's bridge: reloads only reach the panel while this window controls it (another tab may own it).
    private weak var bridge: QuickLookPanelBridge?

    init(bridge: QuickLookPanelBridge?) { self.bridge = bridge }

    var isVisible: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }

    var isControlling: Bool {
        guard isVisible, let bridge else { return false }
        return QLPreviewPanel.shared().dataSource === bridge
    }

    func show() {
        let panel = QLPreviewPanel.shared()!
        panel.updateController()
        if panel.dataSource === bridge { panel.reloadData() }
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        guard QLPreviewPanel.sharedPreviewPanelExists() else { return }
        QLPreviewPanel.shared().orderOut(nil)
    }

    func reloadData() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(),
              let bridge, panel.dataSource === bridge else { return }
        panel.reloadData()
    }
}

/// Space → Quick Look over the selection, in display order (spec §11). One per window; the window controller rebinds
/// it on every navigation, and selection or listing changes reload the panel while it is visible.
///
/// Items are lazy: while the panel is hidden (or controlled by another window or tab) a selection or listing change only drops the built items, so a
/// ⌘A in a huge folder builds no URLs until Quick Look opens (or the panel asks for them).
@MainActor
final class QuickLookController {
    private let panel: @MainActor () -> any QuickLookPanelControlling
    /// A folder or search results (P3-10).
    private weak var folder: (any RowSource)?
    private var token: ObserverToken?
    private var builtItems: [URL]?
    /// How many times `items` was built from the selection (tests: a hidden panel builds none).
    private(set) var itemBuilds = 0

    init(panel: @escaping @MainActor () -> any QuickLookPanelControlling) { self.panel = panel }

    var isVisible: Bool { panel().isVisible }

    /// The selection's URLs in display order, built on first use after a change.
    var items: [URL] {
        if let builtItems { return builtItems }
        let built = buildItems()
        builtItems = built
        return built
    }

    func bind(_ folder: (any RowSource)?) {
        token?.cancel()
        token = nil
        self.folder = folder
        token = folder?.observeRows { [weak self] event in
            switch event {
            case .selection, .changes: self?.selectionChanged()
            case .beginRename: break
            }
        }
        selectionChanged()
    }

    /// Reloads the visible panel (tab switches: the panel's new controller supplies its own items).
    func reloadIfVisible() {
        let p = panel()
        if p.isVisible { p.reloadData() }
    }

    private func buildItems() -> [URL] {
        itemBuilds += 1
        return folder?.selectedURLs ?? []
    }

    /// Hidden, or shown by another window or tab: forget the built items (no URLs are built). Controlled by this
    /// window: rebuild and reload when they changed.
    private func selectionChanged() {
        let p = panel()
        guard p.isControlling else { builtItems = nil; return }
        let previous = builtItems
        let next = buildItems()
        builtItems = next
        if next != previous { p.reloadData() }
    }

    /// Space: closes a visible panel; otherwise opens it over the selection (nothing selected: nothing happens).
    func toggle() {
        let p = panel()
        if p.isVisible { p.hide(); return }
        builtItems = buildItems()
        guard !items.isEmpty else { return }
        p.show()
    }

    /// Esc in the content: closes a visible panel (Finder parity). False when there was nothing to close.
    @discardableResult
    func hideIfVisible() -> Bool {
        let p = panel()
        guard p.isVisible else { return false }
        p.hide()
        return true
    }

    /// Keys pressed while the panel is key. Space closes it. With ≤ 1 item, plain and ⇧ arrows go to the list
    /// (`forward`), so the selection moves and the panel follows; with several, the panel's own ←/→ steps through them.
    func handlePanelKey(_ chord: KeyChord, forward: (KeyChord) -> Void) -> Bool {
        switch chord.key {
        case .space where chord.modifiers.isEmpty:
            panel().hide()
            return true
        case .up, .down, .left, .right:
            guard chord.modifiers.isEmpty || chord.modifiers == [.shift], items.count <= 1 else { return false }
            forward(chord)
            return true
        default:
            return false
        }
    }
}

/// QLPreviewPanel data source + delegate. Owned by the window controller. The Quartz protocols carry no actor
/// annotation, but the panel calls them on the main thread (it is an NSPanel); `@preconcurrency` checks that at run time.
@MainActor
final class QuickLookPanelBridge: NSObject, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    var controller: QuickLookController?
    /// The active list's keyDown (the first responder does not change).
    var forwardKeyEvent: ((NSEvent) -> Void)?
    /// The item's icon on screen (zoom effect), nil when its row is off-screen.
    var sourceFrame: ((URL) -> NSRect?)?

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { controller?.items.count ?? 0 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let items = controller?.items ?? []
        return (items.indices.contains(index) ? items[index] : items.first) as NSURL?
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown, let controller, let chord = KeyEventTranslator.chord(for: event) else {
            return false
        }
        return controller.handlePanelKey(chord) { [weak self] _ in self?.forwardKeyEvent?(event) }
    }

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        guard let url = (item as? NSURL) as URL? else { return .zero }
        return sourceFrame?(url) ?? .zero
    }
}

/// Lists that give Quick Look a zoom origin for a model row (screen coordinates; nil when the row is off-screen).
@MainActor protocol QuickLookSourceList: AnyObject {
    func quickLookSourceFrame(forModelRow row: Int) -> NSRect?
}

extension DetailsViewController: QuickLookSourceList {}
extension IconsViewController: QuickLookSourceList {}
