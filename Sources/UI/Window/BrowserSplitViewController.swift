import AppKit
import Core

/// Sidebar + content + the preview pane (§5.1; P3-12: the inspector item, toggled with ⌥P, collapsed unless
/// `Settings.previewPaneVisible`, its dragged width persisted in `Settings.previewPaneWidth`).
///
/// Sizing: the pane never takes more than a share of the window (`textMaximumShare`, or `quickLookMaximumShare`
/// while it shows Quick Look content, which benefits from room). Until the user drags it, it opens at
/// `defaultShare` of the window. Whenever the window (or its screen) changes size, the pane re-fits: the user's
/// width when it fits under the cap, the cap otherwise, so it never crowds the file list.
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
    static let defaultShare: CGFloat = 0.3
    static let textMaximumShare: CGFloat = 0.45
    static let quickLookMaximumShare: CGFloat = 0.65
    /// The pane shows Quick Look content (images, PDFs, Original documents): the wider cap applies.
    private(set) var previewShowsQuickLook = false
    private var lastSplitWidth: CGFloat = 0
    private var refitScheduled = false

    init(context: UIContext, session: BrowserSession) {
        self.context = context
        self.session = session
        self.previewPane = PreviewPaneController(context: context)
        super.init(nibName: nil, bundle: nil)
        previewPane.onQuickLookContentChange = { [weak self] quickLook in self?.setPreviewShowsQuickLook(quickLook) }
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
        item.maximumThickness = Self.previewMinimumWidth / Self.textMaximumShare   // until the window has a width
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
        if !previewItem.isCollapsed { setPreviewWidth(preferredPreviewWidth()) }
        previewWidthRestored = true
    }

    /// The widest the pane may be in a window this wide (never under the minimum).
    func maximumPreviewWidth(splitWidth: CGFloat? = nil) -> CGFloat {
        let width = splitWidth ?? splitView.bounds.width
        let share = previewShowsQuickLook ? Self.quickLookMaximumShare : Self.textMaximumShare
        return max(Self.previewMinimumWidth, (width * share).rounded(.down))
    }

    /// The width the pane opens and re-fits at: the dragged width, or `defaultShare` of the window, within limits.
    func preferredPreviewWidth(splitWidth: CGFloat? = nil) -> Double {
        let width = splitWidth ?? splitView.bounds.width
        let wanted = settings.hasStoredPreviewPaneWidth ? CGFloat(settings.previewPaneWidth) : (width * Self.defaultShare).rounded()
        return Double(min(max(wanted, Self.previewMinimumWidth), maximumPreviewWidth(splitWidth: width)))
    }

    /// Moves the divider before the inspector so the pane is `width` points wide (clamped by the item's limits,
    /// and by the window: a window too narrow for `width` shows a narrower pane). Never persisted — only a divider
    /// drag stores a width.
    func setPreviewWidth(_ width: Double) {
        let index = splitViewItems.count - 2
        view.layoutSubtreeIfNeeded()          // an item just un-collapsed has no frame until layout runs
        updatePreviewLimits()
        let clamped = min(max(CGFloat(width), Self.previewMinimumWidth), previewItem.maximumThickness)
        splitView.setPosition(splitView.bounds.width - clamped - splitView.dividerThickness, ofDividerAt: index)
        lastSplitWidth = splitView.bounds.width
    }

    private func updatePreviewLimits() {
        let maximum = maximumPreviewWidth()
        if previewItem.maximumThickness != maximum { previewItem.maximumThickness = maximum }
    }

    /// Quick Look content gets the wider cap; text goes back to the narrower one (and the pane re-fits).
    func setPreviewShowsQuickLook(_ quickLook: Bool) {
        guard quickLook != previewShowsQuickLook else { return }
        previewShowsQuickLook = quickLook
        scheduleRefit(force: true)
    }

    /// The window resized (a screen change, a zoom, a drag of its edge): re-fit the pane after this layout pass.
    override func viewDidLayout() {
        super.viewDidLayout()
        if abs(splitView.bounds.width - lastSplitWidth) >= 1 { scheduleRefit(force: false) }
    }

    private func scheduleRefit(force: Bool) {
        guard !refitScheduled else { return }
        refitScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.refitScheduled = false
            self.refitPreview(force: force)
        }
    }

    private func refitPreview(force: Bool) {
        guard previewWidthRestored, !isAnimatingPreview, let item = previewItem, !item.isCollapsed,
              (splitView as? DividerTrackingSplitView)?.isTrackingDivider != true else {
            if previewItem != nil { updatePreviewLimits() }
            return
        }
        let width = splitView.bounds.width
        guard force || abs(width - lastSplitWidth) >= 1 else { return }
        let target = preferredPreviewWidth(splitWidth: width)
        if abs(Double(previewPane.view.frame.width) - target) >= 1 || item.maximumThickness != maximumPreviewWidth() {
            setPreviewWidth(target)
        }
        lastSplitWidth = width
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
        let width = preferredPreviewWidth()
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
