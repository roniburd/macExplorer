import AppKit
import Core
import MacxFS

/// Groups (P2-10): header rows, collapse and expand, the selection kept off hidden rows.
extension DetailsViewController {
    /// `.groups(runs)` from the folder: the `.changes(.reset)` that follows reloads the table.
    func applyGroups(_ runs: [GroupRun]) {
        setGroups(runs)
    }

    func setGroups(_ runs: [GroupRun]) {
        guard !runs.isEmpty else { groupedRows = nil; return }
        let present = Set(runs.map(\.key))
        collapsed = collapsed.intersection(present)
        groupedRows = GroupedRows(runs: runs, collapsed: collapsed)
    }

    var groupRuns: [GroupRun] { groupedRows?.runs ?? [] }

    func isCollapsed(group index: Int) -> Bool {
        guard let groupedRows, groupRuns.indices.contains(index) else { return false }
        return groupedRows.collapsed.contains(groupedRows.runs[index].key)
    }

    /// Collapses or expands group `index` (a header click, its disclosure button, ←/→).
    func toggleGroup(_ index: Int) {
        guard groupRuns.indices.contains(index) else { return }
        let key = groupRuns[index].key
        if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
        regroupTable()
    }

    func collapseAllGroups() {
        collapsed = Set(groupRuns.map(\.key))
        regroupTable()
    }

    func expandAllGroups() {
        collapsed = []
        regroupTable()
    }

    /// Before a rename, a scroll to a row or a new item's rename: its group must be visible.
    func expandGroup(containingModelRow row: Int) {
        guard let groupedRows, groupedRows.tableRow(forModelRow: row) == nil,
              let group = groupedRows.group(containingModelRow: row) else { return }
        collapsed.remove(groupedRows.runs[group].key)
        regroupTable()
    }

    func regroupTable() {
        guard let runs = groupedRows?.runs else { return }
        groupedRows = GroupedRows(runs: runs, collapsed: collapsed)
        tableView.reloadData()
        deselectHiddenRows()
        renameController?.relayout()
        reloadSelectionDrawing()
    }

    /// QA round 2: an item hidden by a collapse never stays selected, so no command acts on items the user cannot
    /// see. A collapse (header click, ←, Collapse All) drops them from the selection; the cursor stays put, so a
    /// cursor inside the collapsed group navigates from its header and → expands it again.
    private func deselectHiddenRows() {
        guard let folder else { return }
        let hidden = mapping.hiddenModelRows, rows = folder.selection.rows
        guard !rows.isDisjoint(with: hidden) else { return }
        folder.select(.set(rows.subtracting(hidden), cursor: folder.selection.cursor.flatMap { folder.row(of: $0) }))
    }

    /// An item selected while its group is collapsed (renamed or moved into it, a pasted or new item, a select by
    /// name) expands that group instead. True when it regrouped the table, which redraws the selection.
    func revealSelectedHiddenRows(_ folder: FolderModel) -> Bool {
        guard let groupedRows else { return false }
        let selectedHidden = folder.selection.rows.intersection(mapping.hiddenModelRows)
        guard !selectedHidden.isEmpty else { return false }
        for row in selectedHidden {
            if let group = groupedRows.group(containingModelRow: row) { collapsed.remove(groupedRows.runs[group].key) }
        }
        regroupTable()
        return true
    }

    func headerView(_ group: Int) -> NSView {
        let view = tableView.makeView(withIdentifier: GroupHeaderView.reuseID, owner: nil) as? GroupHeaderView ?? GroupHeaderView()
        let run = groupRuns[group]
        view.configure(title: GroupTitles.title(for: run.key), count: run.rows.count, collapsed: isCollapsed(group: group),
                       groupIndex: group)
        view.onToggle = { [weak self] in self?.toggleGroup($0) }
        return view
    }

    /// ← collapses the group of the cursor row, → expands it (grouped, no ⌘/⌥/⌃).
    func handleGroupKey(_ event: NSEvent, folder: FolderModel) -> Bool {
        guard let groupedRows, let key = NavKey(event.specialKey), key == .left || key == .right,
              event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
              let cursor = folder.selection.cursor.flatMap({ folder.row(of: $0) }),
              let group = groupedRows.group(containingModelRow: cursor) else { return false }
        typeSelect.reset()
        if isCollapsed(group: group) == (key == .right) { toggleGroup(group) }
        return true
    }

    /// Right-click rule through the mapping. A header gets Collapse All / Expand All, then the empty-space menu.
    func contextMenu(forTableRow row: Int) -> NSMenu? {
        guard mapping.groupIndex(forTableRow: row) != nil else {
            return contextMenuProvider?(row >= 0 ? mapping.modelRow(forTableRow: row) : nil)
        }
        let menu = contextMenuProvider?(nil) ?? NSMenu()
        menu.insertItem(.separator(), at: 0)
        let expand = ClosureMenuItem(title: L10n.string("Expand All Groups")) { [weak self] in self?.expandAllGroups() }
        expand.identifier = NSUserInterfaceItemIdentifier("macx.menu.expandAllGroups")
        menu.insertItem(expand, at: 0)
        let collapse = ClosureMenuItem(title: L10n.string("Collapse All Groups")) { [weak self] in self?.collapseAllGroups() }
        collapse.identifier = NSUserInterfaceItemIdentifier("macx.menu.collapseAllGroups")
        menu.insertItem(collapse, at: 0)
        return menu
    }

    /// Scenario click target "group:<title>": toggles the group with that title.
    @discardableResult
    func toggleGroup(titled title: String) -> Bool {
        guard let index = groupRuns.firstIndex(where: { GroupTitles.title(for: $0.key) == title }) else { return false }
        toggleGroup(index)
        return true
    }
}
