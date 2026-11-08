import AppKit
import Core

/// A press that may become a selection box: armed on mouse-down, drawn once the drag passes the drag threshold.
struct DetailsBandDrag {
    let start: NSPoint          // table coordinates (document space: fixed while autoscrolling)
    let startWindow: NSPoint
    let mode: RubberBand.Mode
    let base: IndexSet          // the selection before the press (⇧ adds to it, ⌘ toggles it)
    var overlay: RubberBandView?
}

/// Rubber band in Details (owner's design 2026-11-07, Windows Explorer style). The icon + name text of a row, or
/// anywhere on a selected row, is the item: a click selects it and a drag moves files, as before. A press anywhere
/// else (the blank part of a row, other columns, the empty space below the rows) still clicks as before, but a drag
/// draws a selection box over every row it touches. ⇧ adds, ⌘ toggles (§5.5).
extension DetailsViewController {
    /// Slack around the name text, so a press just past the last letter still grabs the file.
    private static let grabSlack: CGFloat = 4

    var isTrackingRubberBand: Bool { bandDrag != nil }

    /// Whether a single press at `point` (table coordinates) on `modelRow` hits the item rather than blank space.
    func pressIsOnItem(modelRow: Int?, tableRow: Int, at point: NSPoint) -> Bool {
        guard let source, let modelRow, modelRow < source.rowCount else { return false }
        if source.selection.rows.contains(modelRow) { return true }
        return nameGrabRect(modelRow: modelRow, tableRow: tableRow)?.contains(point) ?? false
    }

    /// The icon and name text of a row, in table coordinates, laid out as NameCellView draws them (icon at +2, text
    /// 6 after it, no wider than the cell). Measured from the model, so it holds before the cell view exists.
    func nameGrabRect(modelRow: Int, tableRow: Int) -> NSRect? {
        guard let source else { return nil }
        let column = tableView.column(withIdentifier: DetailsColumns.identifier(.name))
        guard column >= 0 else { return nil }
        let cell = tableView.frameOfCell(atColumn: column, row: tableRow)
        let font = source.isCut(row: modelRow) ? CellStyle.italicFont : CellStyle.font
        let text = (source.displayName(atRow: modelRow) as NSString).size(withAttributes: [.font: font]).width
        let textStart = NameCellView.iconLeading + CGFloat(iconPoints) + NameCellView.iconTextGap
        let width = min(textStart + ceil(text), cell.width)
        return NSRect(x: cell.minX - Self.grabSlack, y: cell.minY, width: width + 2 * Self.grabSlack, height: cell.height)
    }

    func armRubberBand(at point: NSPoint, event: NSEvent, base: IndexSet) {
        bandDrag = DetailsBandDrag(start: point, startWindow: event.locationInWindow,
                                   mode: RubberBand.mode(for: event.modifierFlags), base: base)
    }

    /// Mouse-dragged while armed: past the threshold the box appears and follows the pointer.
    func dragRubberBand(_ event: NSEvent) {
        guard var band = bandDrag else { return }
        if band.overlay == nil {
            guard RightDragTracker.exceedsThreshold(from: band.startWindow, to: event.locationInWindow) else { return }
            mouse.cancelPendingForDrag()
            band.overlay = RubberBandView(frame: NSRect(origin: band.start, size: .zero))
        }
        guard let overlay = band.overlay else { return }
        bandDrag = band
        tableView.autoscroll(with: event)
        // Row views added while scrolling would cover the box: keep it the topmost subview.
        if tableView.subviews.last !== overlay { tableView.addSubview(overlay, positioned: .above, relativeTo: nil) }
        let rect = RubberBand.rect(from: band.start, to: tableView.convert(event.locationInWindow, from: nil))
        overlay.frame = rect
        applyRubberBand(rect: rect, mode: band.mode, base: band.base)
    }

    func endRubberBand() {
        bandDrag?.overlay?.removeFromSuperview()
        bandDrag = nil
    }

    /// Every item row the box spans vertically (group headers never), combined with `base` by `mode`.
    func applyRubberBand(rect: NSRect, mode: RubberBand.Mode, base: IndexSet) {
        guard let source else { return }
        var hits = IndexSet()
        let span = NSRect(x: tableView.bounds.minX, y: rect.minY, width: tableView.bounds.width, height: max(rect.height, 0.5))
        let range = tableView.rows(in: span)
        for tableRow in range.location..<(range.location + range.length) {
            if let model = mapping.modelRow(forTableRow: tableRow), model < source.rowCount { hits.insert(model) }
        }
        source.select(.set(RubberBand.selection(base: base, hits: hits, mode: mode), cursor: hits.last))
        reloadSelectionDrawing()
    }
}
