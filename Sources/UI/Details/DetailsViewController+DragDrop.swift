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
        dragSource.begin(event: event, rows: rows, folder: folder, view: tableView, rowFrame: { [tableView] in tableView.rect(ofRow: $0) },
                         secondary: false)
    }

    func handleRightMouseDown(_ event: NSEvent) {
        rightDrag.rightMouseDown(at: event.locationInWindow)
        rightDownEvent = event
    }

    func handleRightMouseDragged(_ event: NSEvent) {
        guard rightDrag.rightMouseDragged(to: event.locationInWindow) == .beginDrag, let folder, let down = rightDownEvent else { return }
        let row = tableView.row(at: tableView.convert(down.locationInWindow, from: nil))
        guard row >= 0, row < folder.rowCount else { return }
        if !folder.selection.rows.contains(row) { folder.select(.set(IndexSet(integer: row), cursor: row)) }
        reloadSelectionDrawing()
        dragSource.begin(event: event, rows: folder.selection.rows, folder: folder, view: tableView,
                         rowFrame: { [tableView] in tableView.rect(ofRow: $0) }, secondary: true)
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
        let row = tableView.row(at: tableView.convert(info.draggingLocation, from: nil))
        guard row >= 0, row < folder.rowCount, SpringLoadPolicy.opens(folder.entry(atRow: row).kind) else { return nil }
        return folder.url(atRow: row)
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard let folder, let dropTarget else { return [] }
        let result = DropRetarget.destination(row: row, onRow: dropOperation == .on, folder: folder)
        if result.retargetToFolder { tableView.setDropRow(-1, dropOperation: .on) }   // highlight the whole list
        return dropTarget.validate(info, destination: result.url)
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let folder, let dropTarget else { return false }
        return dropTarget.perform(info, destination: DropRetarget.destination(row: row, onRow: dropOperation == .on, folder: folder).url,
                                  in: tableView)
    }
}
