import AppKit
import Core
import MacxFS

/// ScenarioProbe conformance (overview §3.14): model values plus the hooks later tasks install.
extension BrowserWindowController {
    var probeFolderURL: URL { session.folder.directory }

    var probeRowNames: [String] {
        let folder = session.folder
        return (0..<folder.rowCount).map { folder.name(atRow: $0) }
    }

    var probeSelectedNames: [String] {
        let folder = session.folder
        return folder.selection.rows.map { folder.name(atRow: $0) }
    }

    var probeCutNames: [String] {
        let folder = session.folder
        guard !folder.cutNames.isEmpty else { return [] }
        return (0..<folder.rowCount).filter { folder.isCut(row: $0) }.map { folder.name(atRow: $0) }
    }

    var probeFolderState: FolderState { session.folder.state }

    /// From the first responder: the address field (or its field editor) → .addressBar, any other field editor →
    /// .fieldEditor, otherwise the focus context of the CommandHandlingViewController up the responder chain.
    var probeFocus: FocusContext {
        guard let responder = window?.firstResponder else { return .content }
        if let editor = responder as? NSText, editor.isFieldEditor {
            return Self.isInAddressBar(editor.delegate as? NSView) ? .addressBar : .fieldEditor
        }
        if Self.isInAddressBar(responder as? NSView) { return .addressBar }
        var next: NSResponder? = responder
        while let current = next {
            if let pane = current as? CommandHandlingViewController { return pane.focusContext }
            next = current.nextResponder
        }
        return .content
    }

    var probeViewMode: ViewMode { session.viewMode }
    var probeAddressText: String { scenarioHooks.addressText?() ?? "" }
    var probeIsEditingAddress: Bool { scenarioHooks.isEditingAddress?() ?? false }
    var probeRenameText: String? { scenarioHooks.renameText?() ?? nil }
    var probeEmptyStateText: String? { scenarioHooks.emptyStateText?() ?? nil }
    var probeBannerText: String? { scenarioHooks.bannerText?() ?? nil }

    var probeFieldEditorText: String? {
        guard let editor = window?.firstResponder as? NSText, editor.isFieldEditor else { return nil }
        return editor.string
    }

    var probeTabFolderURLs: [URL] {
        guard let window else { return [session.folder.directory] }
        return TabController.orderedTabs(of: window).compactMap {
            ($0.windowController as? BrowserWindowController)?.session.folder.directory
        }
    }

    var probeSelectedTabIndex: Int {
        guard let window else { return 0 }
        let selected = window.tabGroup?.selectedWindow ?? window
        return TabController.orderedTabs(of: window).firstIndex { $0 === selected } ?? 0
    }

    var probeSort: MacxFS.SortDescriptor { session.folder.query.sort }
    var probeGrouping: GroupBy { session.folder.grouping }
    var probeIconSize: IconSize { session.viewState.iconSize }

    func probePerformDrop(sources: [URL], onto targetName: String, modifiers: DragModifiers, secondary: Bool,
                          menuChoice: DragOperation?) async {
        await scenarioHooks.performDrop?(sources, targetName, modifiers, secondary, menuChoice)
    }

    private static func isInAddressBar(_ view: NSView?) -> Bool {
        var current = view
        while let v = current {
            let id = v.accessibilityIdentifier()
            if id == AXID.addressField || id == AXID.addressBar { return true }
            current = v.superview
        }
        return false
    }
}
