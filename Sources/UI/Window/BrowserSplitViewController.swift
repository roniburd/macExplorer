import AppKit
import Core

/// Sidebar + content + the preview pane (§5.1; P3-12: the inspector item, toggled with ⌥P, collapsed unless
/// `Settings.previewPaneVisible`, its width persisted in `Settings.previewPaneWidth`).
@MainActor
final class BrowserSplitViewController: NSSplitViewController {
    let context: UIContext
    let session: BrowserSession
    let previewPane: PreviewPaneController
    private(set) var previewItem: NSSplitViewItem!
    /// True while a show/hide runs (animated or not): the intermediate widths are never persisted.
    private(set) var isAnimatingPreview = false
    /// The stored width is applied once the view appears; until then the split view's layout passes would
    /// otherwise overwrite it with a default width.
    private var previewWidthRestored = false
    private var settings: Settings { context.environment.settings }

    static let previewMinimumWidth: CGFloat = 220
    static let previewMaximumWidth: CGFloat = 600

    init(context: UIContext, session: BrowserSession) {
        self.context = context
        self.session = session
        self.previewPane = PreviewPaneController(context: context)
        super.init(nibName: nil, bundle: nil)
        let tracking = DividerTrackingSplitView()
        tracking.isVertical = splitView.isVertical
        tracking.dividerStyle = splitView.dividerStyle
        splitView = tracking

        let sidebar = SidebarViewController(context: context, session: session)
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 160
        sidebarItem.maximumThickness = 400
        sidebarItem.canCollapse = true
        addSplitViewItem(sidebarItem)

        let content = ContentViewController(context: context, session: session)
        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = 320
        addSplitViewItem(contentItem)

        installPreviewItem()
    }

    /// The sidebar split item's controller.
    var sidebarController: SidebarViewController? {
        splitViewItems.lazy.compactMap { $0.viewController as? SidebarViewController }.first
    }

    /// The content split item's controller (the inspector comes after it).
    var contentController: ContentViewController? {
        splitViewItems.lazy.compactMap { $0.viewController as? ContentViewController }.first
    }

    /// This window's pane is shown (or showing): true from the moment a toggle starts to show it.
    var isPreviewPaneVisible: Bool { previewPane.isActive }

    private func installPreviewItem() {
        let item = NSSplitViewItem(inspectorWithViewController: previewPane)
        item.minimumThickness = Self.previewMinimumWidth
        item.maximumThickness = Self.previewMaximumWidth
        item.canCollapse = true
        item.isCollapsed = !settings.previewPaneVisible
        addSplitViewItem(item)
        previewItem = item
        previewPane.isActive = !item.isCollapsed
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !previewWidthRestored else { return }
        // Settings owns the pane's state; the divider autosave (non-sandboxed runs) may have restored another.
        if previewItem.isCollapsed == settings.previewPaneVisible { previewItem.isCollapsed = !settings.previewPaneVisible }
        previewPane.isActive = !previewItem.isCollapsed
        if !previewItem.isCollapsed { setPreviewWidth(settings.previewPaneWidth) }
        previewWidthRestored = true
    }

    /// Moves the divider before the inspector so the pane is `width` points wide (clamped by the item's limits,
    /// and by the window: a window too narrow for `width` shows a narrower pane). Never persisted — only a divider
    /// drag stores a width.
    func setPreviewWidth(_ width: Double) {
        let index = splitViewItems.count - 2
        let clamped = min(max(CGFloat(width), Self.previewMinimumWidth), Self.previewMaximumWidth)
        view.layoutSubtreeIfNeeded()          // an item just un-collapsed has no frame until layout runs
        splitView.setPosition(splitView.bounds.width - clamped - splitView.dividerThickness, ofDividerAt: index)
    }

    /// Preview (item context menu, View › Show in Preview Pane): opens the pane if it is hidden; it shows the selection.
    func showPreviewPane() {
        if previewItem.isCollapsed { togglePreviewPane() }
    }

    /// View › Show / Hide Preview Pane (⌥P): animated when the window is on screen; persists the visibility.
    func togglePreviewPane() {
        let show = previewItem.isCollapsed
        settings.previewPaneVisible = show
        previewPane.isActive = show
        previewToggleSerial += 1
        let serial = previewToggleSerial
        let onScreen = view.window?.occlusionState.contains(.visible) ?? false
        isAnimatingPreview = true
        guard onScreen, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            previewItem.isCollapsed = !show
            finishPreviewToggle(show: show, serial: serial)
            return
        }
        NSAnimationContext.runAnimationGroup({ _ in
            previewItem.animator().isCollapsed = !show
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.finishPreviewToggle(show: show, serial: serial) }
        })
        // AppKit can skip the completion of an animation it never ran (window hidden mid-way): never stay stuck.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.finishPreviewToggle(show: show, serial: serial)
        }
    }

    private var previewToggleSerial = 0
    private var finishedToggleSerial = 0

    /// Once per toggle (animation completion or the fallback, whichever comes first): stop ignoring resizes and give
    /// a shown pane its stored width.
    private func finishPreviewToggle(show: Bool, serial: Int) {
        guard serial == previewToggleSerial, finishedToggleSerial != serial else { return }
        finishedToggleSerial = serial
        isAnimatingPreview = false
        previewWidthRestored = true
        guard show, !previewItem.isCollapsed else { return }
        let width = settings.previewPaneWidth
        if abs(Double(previewPane.view.frame.width) - width) >= 1 { setPreviewWidth(width) }
    }

    /// Persists the pane's width only while the user drags a divider (QA round 2): programmatic widths
    /// (`setPreviewWidth`, the toggle), window resizes and the clamps a narrow window forces are layout, not intent —
    /// storing them would replace the user's width with whatever currently fits.
    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        guard let item = previewItem, !item.isCollapsed, !isAnimatingPreview, previewWidthRestored,
              (splitView as? DividerTrackingSplitView)?.isTrackingDivider == true else { return }
        let width = Double(item.viewController.view.frame.width)
        if width >= Double(Self.previewMinimumWidth), abs(width - settings.previewPaneWidth) >= 1 { settings.previewPaneWidth = width }
    }

    required init?(coder: NSCoder) { fatalError("BrowserSplitViewController is created in code") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Sandbox mode sets no autosave names (overview Global Constraints › Safety).
        if !context.options.isSandboxed { splitView.autosaveName = "macx.browser.split" }
    }

    // Dragging the divider past the sidebar's minimum must not collapse it to zero width —
    // a drag-collapsed sidebar can't be dragged back open. Hiding stays available through
    // View › Show/Hide Sidebar (⌃⌘S), which collapses programmatically and isn't affected.
    override func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        false
    }

    override func splitView(_ splitView: NSSplitView, shouldCollapseSubview subview: NSView,
                            forDoubleClickOnDividerAt dividerIndex: Int) -> Bool {
        false
    }
}

/// Knows when the user is dragging one of its dividers: NSSplitView runs the whole drag inside `mouseDown`, and
/// only a press on a divider reaches the split view itself (presses elsewhere land in its subviews).
@MainActor
final class DividerTrackingSplitView: NSSplitView {
    private(set) var isTrackingDivider = false

    override func mouseDown(with event: NSEvent) {
        isTrackingDivider = true
        defer { isTrackingDivider = false }
        super.mouseDown(with: event)
    }
}
