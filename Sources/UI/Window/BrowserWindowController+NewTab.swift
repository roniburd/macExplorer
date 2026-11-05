import AppKit
import Core
import MacxFS

/// Scenario hooks for new tabs (P2-06): `middleClick` and `click` steps on content rows and `tree:` nodes run the same
/// gesture paths as the real mouse. `tree:` paths are relative to --root and must stay inside it.
extension BrowserWindowController {
    func installNewTabHooks() {
        scenarioHooks.performMiddleClick = { [weak self] target in
            await self?.scenarioMiddleClick(target) ?? false
        }
        scenarioHooks.clickTarget = { [weak self] target, modifiers in
            await self?.scenarioClick(target, modifiers: modifiers) ?? false
        }
    }

    private var sidebarController: SidebarViewController? { sidebarPane as? SidebarViewController }
    private var contentController: ContentViewController? { contentPane as? ContentViewController }

    private func scenarioMiddleClick(_ target: String) async -> Bool {
        if let url = treeURL(target) {
            guard let sidebar = sidebarController, let row = await sidebar.revealRow(for: url) else { return false }
            return sidebar.handleNewTabGesture(.middleClick, row: row)
        }
        guard let content = contentController, let row = session.folder.row(named: target) else { return false }
        return content.newTabGesture(.middleClick, row: row)
    }

    /// `tree:` and `group:` targets (P2-16 adds `header:`). For `tree:`, "cmd" is the ⌘-click path; otherwise a plain
    /// click selects the node and navigates to it. `group:<title>` toggles that group of the Details list.
    private func scenarioClick(_ target: String, modifiers: [String]) async -> Bool {
        if target.hasPrefix("group:") {
            return contentController?.details.toggleGroup(titled: String(target.dropFirst("group:".count))) ?? false
        }
        guard let url = treeURL(target), let sidebar = sidebarController,
              let row = await sidebar.revealRow(for: url) else { return false }
        if modifiers.contains("cmd") { return sidebar.handleNewTabGesture(.commandClick, row: row) }
        sidebar.select(row: row)
        sidebar.activateRow(row)
        return true
    }

    /// `root/<rel>` for "tree:<rel>" ("" = the root), nil for other targets, without --root, or for unsafe paths.
    private func treeURL(_ target: String) -> URL? {
        guard target.hasPrefix("tree:"), let root = context.options.root else { return nil }
        let relative = String(target.dropFirst("tree:".count))
        if relative.isEmpty { return root }
        guard ScenarioPath.isSafeRelative(relative) else { return nil }
        return root.appending(path: relative, directoryHint: .isDirectory)
    }
}
