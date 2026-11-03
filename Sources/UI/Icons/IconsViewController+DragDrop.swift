import AppKit
import Core
import MacxFS

/// Drag source, right-drag and drop destination for the Icons grid (§5.6, P1-36).
extension IconsViewController {
    func handleMouseDragged(_ event: NSEvent) {
        guard let folder, let start = mouse.mouseDownWindowPoint, let row = mouse.mouseDownRow, !dragSource.isDragging,
              RightDragTracker.exceedsThreshold(from: start, to: event.locationInWindow) else { return }
        mouse.cancelPendingForDrag()
        let rows = folder.selection.rows.contains(row) ? folder.selection.rows : IndexSet(integer: row)
        dragSource.begin(event: event, rows: rows, folder: folder, view: collectionView, rowFrame: { [layout] in layout.frame(forItem: $0) },
                         secondary: false)
    }

    func handleRightMouseDown(_ event: NSEvent) {
        rightDrag.rightMouseDown(at: event.locationInWindow)
        rightDownEvent = event
    }

    func handleRightMouseDragged(_ event: NSEvent) {
        guard rightDrag.rightMouseDragged(to: event.locationInWindow) == .beginDrag, let folder, let down = rightDownEvent,
              let row = layout.itemIndex(at: collectionView.convert(down.locationInWindow, from: nil)), row < folder.rowCount else { return }
        if !folder.selection.rows.contains(row) { folder.select(.set(IndexSet(integer: row), cursor: row)) }
        reloadSelectionDrawing()
        dragSource.begin(event: event, rows: folder.selection.rows, folder: folder, view: collectionView,
                         rowFrame: { [layout] in layout.frame(forItem: $0) }, secondary: true)
    }

    func handleRightMouseUp(_ event: NSEvent) {
        if case .showMenu = rightDrag.rightMouseUp(at: event.locationInWindow), let down = rightDownEvent,
           let menu = collectionView.menu(for: down) {
            NSMenu.popUpContextMenu(menu, with: down, for: collectionView)
        }
        rightDownEvent = nil
    }

    func springLoadTarget(_ info: any NSDraggingInfo) -> URL? {
        guard let folder, let row = layout.itemIndex(at: collectionView.convert(info.draggingLocation, from: nil)),
              row < folder.rowCount, SpringLoadPolicy.opens(folder.entry(atRow: row).kind) else { return nil }
        return folder.url(atRow: row)
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: any NSDraggingInfo,
                        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        guard let folder, let dropTarget else { return [] }
        let result = DropRetarget.destination(row: proposedDropIndexPath.pointee.item, onRow: proposedDropOperation.pointee == .on,
                                              folder: folder)
        if result.retargetToFolder { proposedDropOperation.pointee = .before }
        return dropTarget.validate(draggingInfo, destination: result.url)
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: any NSDraggingInfo, indexPath: IndexPath,
                        dropOperation: NSCollectionView.DropOperation) -> Bool {
        guard let folder, let dropTarget else { return false }
        let result = DropRetarget.destination(row: indexPath.item, onRow: dropOperation == .on, folder: folder)
        return dropTarget.perform(draggingInfo, destination: result.url, in: collectionView)
    }
}
