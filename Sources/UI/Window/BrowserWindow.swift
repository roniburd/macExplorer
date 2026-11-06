import AppKit

/// The browser's window. Show Next/Previous Tab (⌃Tab, ⌃⇧Tab, Window menu) cycle the tab group here rather than in
/// AppKit: NSWindow's own selectNextTab:/selectPreviousTab: do nothing for tabs that were added in the background
/// (middle-click, ⌘-click a tree node) and never shown yet, and nothing at all while the app cannot activate
/// (QA round 1). Selecting a tab is what clicking it does: the group's selection, then key and front.
@MainActor
final class BrowserWindow: NSWindow {
    override func selectNextTab(_ sender: Any?) {
        if !TabController.cycleTab(of: self, by: 1) { super.selectNextTab(sender) }
    }

    override func selectPreviousTab(_ sender: Any?) {
        if !TabController.cycleTab(of: self, by: -1) { super.selectPreviousTab(sender) }
    }
}
