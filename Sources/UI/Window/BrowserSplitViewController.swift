import AppKit
import Core

/// Sidebar + content (§5.1). The inspector slot is reserved for the Phase 3 preview pane
/// (`NSSplitViewItem(inspectorWithViewController:)` appended after the content item).
@MainActor
final class BrowserSplitViewController: NSSplitViewController {
    let context: UIContext
    let session: BrowserSession

    init(context: UIContext, session: BrowserSession) {
        self.context = context
        self.session = session
        super.init(nibName: nil, bundle: nil)

        let sidebar = SidebarViewController(context: context, session: session)
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 160
        sidebarItem.maximumThickness = 400
        sidebarItem.canCollapse = true
        addSplitViewItem(sidebarItem)

        let content = PlaceholderContentViewController(context: context, session: session)   // P1-31 replaces it with ContentViewController
        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = 320
        addSplitViewItem(contentItem)
    }

    required init?(coder: NSCoder) { fatalError("BrowserSplitViewController is created in code") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Sandbox mode sets no autosave names (overview Global Constraints › Safety).
        if !context.options.isSandboxed { splitView.autosaveName = "macx.browser.split" }
    }
}
