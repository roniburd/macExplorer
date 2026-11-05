import AppKit
import Core
import MacxFS

/// Drag source, right-drag and drop destination for the Details list (§5.6, P1-36).
extension DetailsViewController {
    func handleMouseDragged(_ event: NSEvent) {
        guard let folder, let start = mouse.mouseDownWindowPoint, let row = mouse.mouseDownRow, !dragSource.isDragging,
              RightDragTracker.exceedsThreshold(from: start, to: event.locationInWindow) else { return }
        mouse.cancelPendingForDrag()
        let rows = folder.selection.rows.contains(row) ? folder.selection.rows : IndexSet(integer: row)
        dragSource.begin(event: event, rows: rows, folder: folder, view: tableView, rowFrame: modelRowFrame, secondary: false)
    }

    func handleRightMouseDown(_ event: NSEvent) {
        rightDrag.rightMouseDown(at: event.locationInWindow)
        rightDownEvent = event
    }

    func handleRightMouseDragged(_ event: NSEvent) {
        guard rightDrag.rightMouseDragged(to: event.locationInWindow) == .beginDrag, let folder, let down = rightDownEvent else { return }
        guard let row = mapping.modelRow(forTableRow: tableView.hitRow(at: tableView.convert(down.locationInWindow, from: nil))),
              row < folder.rowCount else { return }
        if !folder.selection.rows.contains(row) { folder.select(.set(IndexSet(integer: row), cursor: row)) }
        reloadSelectionDrawing()
        dragSource.begin(event: event, rows: folder.selection.rows, folder: folder, view: tableView, rowFrame: modelRowFrame,
                         secondary: true)
    }

    /// A model row's frame in the table (zero while its group is collapsed): drag images.
    private func modelRowFrame(_ row: Int) -> NSRect {
        mapping.tableRow(forModelRow: row).map { tableView.rect(ofRow: $0) } ?? .zero
    }

    func handleRightMouseUp(_ event: NSEvent) {
        if case .showMenu = rightDrag.rightMouseUp(at: event.locationInWindow), let down = rightDownEvent,
           let menu = tableView.menu(for: down) {
            NSMenu.popUpContextMenu(menu, with: down, for: tableView)
        }
        rightDownEvent = nil
    }

    func springLoadTarget(_ info: any NSDraggingInfo) -> URL? {
        guard let folder else { return nil }
        guard let row = mapping.modelRow(forTableRow: tableView.hitRow(at: tableView.convert(info.draggingLocation, from: nil))),
              row < folder.rowCount, SpringLoadPolicy.opens(folder.entry(atRow: row).kind) else { return nil }
        return folder.url(atRow: row)
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard let folder, let dropTarget else { return [] }
        let result = DropRetarget.destination(row: mapping.modelRow(forTableRow: row) ?? -1, onRow: dropOperation == .on, folder: folder)
        if result.retargetToFolder { tableView.setDropRow(-1, dropOperation: .on) }   // highlight the whole list
        return dropTarget.validate(info, destination: result.url)
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let folder, let dropTarget else { return false }
        let destination = DropRetarget.destination(row: mapping.modelRow(forTableRow: row) ?? -1, onRow: dropOperation == .on,
                                                   folder: folder)
        return dropTarget.perform(info, destination: destination.url, in: tableView)
    }
}
