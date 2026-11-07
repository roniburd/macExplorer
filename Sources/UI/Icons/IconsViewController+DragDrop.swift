import AppKit
import Core
import MacxFS

/// Drag source, right-drag and drop destination for the Icons grid (§5.6, P1-36).
extension IconsViewController {
    func handleMouseDragged(_ event: NSEvent) {
        guard let source, let start = mouse.mouseDownWindowPoint, let row = mouse.mouseDownRow, !dragSource.isDragging,
              RightDragTracker.exceedsThreshold(from: start, to: event.locationInWindow) else { return }
        mouse.cancelPendingForDrag()
        let rows = source.selection.rows.contains(row) ? source.selection.rows : IndexSet(integer: row)
        dragSource.begin(event: event, rows: rows, source: source, view: collectionView, rowFrame: { [layout] in layout.frame(forItem: $0) },
                         secondary: false)
    }

    func handleRightMouseDown(_ event: NSEvent) {
        rightDrag.rightMouseDown(at: event.locationInWindow)
        rightDownEvent = event
    }

    func handleRightMouseDragged(_ event: NSEvent) {
        guard rightDrag.rightMouseDragged(to: event.locationInWindow) == .beginDrag, let source, let down = rightDownEvent,
              let row = layout.itemIndex(at: collectionView.convert(down.locationInWindow, from: nil)), row < source.rowCount else { return }
        if !source.selection.rows.contains(row) { source.select(.set(IndexSet(integer: row), cursor: row)) }
        reloadSelectionDrawing()
        dragSource.begin(event: event, rows: source.selection.rows, source: source, view: collectionView,
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
        guard let source, let row = layout.itemIndex(at: collectionView.convert(info.draggingLocation, from: nil)),
              row < source.rowCount, SpringLoadPolicy.opens(source.entry(atRow: row).kind) else { return nil }
        return source.url(atRow: row)
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
