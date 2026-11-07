import AppKit
import Core
import MacxFS

/// Drag source, right-drag and drop destination for the Details list (§5.6, P1-36).
extension DetailsViewController {
    func handleMouseDragged(_ event: NSEvent) {
        guard let source, let start = mouse.mouseDownWindowPoint, let row = mouse.mouseDownRow, !dragSource.isDragging,
              RightDragTracker.exceedsThreshold(from: start, to: event.locationInWindow) else { return }
        mouse.cancelPendingForDrag()
        let rows = source.selection.rows.contains(row) ? source.selection.rows : IndexSet(integer: row)
        dragSource.begin(event: event, rows: rows, source: source, view: tableView, rowFrame: modelRowFrame, secondary: false)
    }

    func handleRightMouseDown(_ event: NSEvent) {
        rightDrag.rightMouseDown(at: event.locationInWindow)
        rightDownEvent = event
    }

    func handleRightMouseDragged(_ event: NSEvent) {
        guard rightDrag.rightMouseDragged(to: event.locationInWindow) == .beginDrag, let source, let down = rightDownEvent else { return }
        guard let row = mapping.modelRow(forTableRow: tableView.hitRow(at: tableView.convert(down.locationInWindow, from: nil))),
              row < source.rowCount else { return }
        if !source.selection.rows.contains(row) { source.select(.set(IndexSet(integer: row), cursor: row)) }
        reloadSelectionDrawing()
        dragSource.begin(event: event, rows: source.selection.rows, source: source, view: tableView, rowFrame: modelRowFrame,
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
        guard let source else { return nil }
        guard let row = mapping.modelRow(forTableRow: tableView.hitRow(at: tableView.convert(info.draggingLocation, from: nil))),
              row < source.rowCount, SpringLoadPolicy.opens(source.entry(atRow: row).kind) else { return nil }
        return source.url(atRow: row)
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
