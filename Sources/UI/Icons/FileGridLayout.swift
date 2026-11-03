// Sources/UI/Icons/FileGridLayout.swift
import AppKit
import Core

/// Fixed cell geometry per icon size (§5.5): a cell is icon + a two-line label, never measured per item.
struct GridMetrics {
    static let labelHeight: CGFloat = 30   // two lines of the 11 pt small system font
    var itemSize: NSSize
    var spacing: NSSize
    var insets: NSEdgeInsets

    static func forIconSize(_ size: IconSize) -> GridMetrics {
        let points = CGFloat(size.points)
        return GridMetrics(itemSize: NSSize(width: max(points + 48, 80), height: 6 + points + 4 + labelHeight + 6),
                           spacing: NSSize(width: 8, height: 8),
                           insets: NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10))
    }
}

enum GridDirection: Sendable { case up, down, left, right }

/// Pure-arithmetic grid. frame(forItem:) is O(1), indexes(in:) and layoutAttributesForElements(in:) are
/// O(visible rows), and prepare() keeps no per-item state (§5.5, §12).
@MainActor
final class FileGridLayout: NSCollectionViewLayout {
    var iconSize: IconSize = .medium {
        didSet {
            guard oldValue != iconSize else { return }
            metrics = .forIconSize(iconSize)
            invalidateLayout()
        }
    }
    var itemCount: Int = 0
    private(set) var metrics = GridMetrics.forIconSize(.medium)
    /// Width used when the layout isn't attached to a collection view (unit tests).
    var fallbackWidth: CGFloat = 600
    private var preparedWidth: CGFloat = 0

    var availableWidth: CGFloat {
        guard let collectionView else { return fallbackWidth }
        return collectionView.enclosingScrollView?.contentSize.width ?? collectionView.bounds.width
    }
    private var columnPitch: CGFloat { metrics.itemSize.width + metrics.spacing.width }
    private var rowPitch: CGFloat { metrics.itemSize.height + metrics.spacing.height }

    var columns: Int {
        let usable = availableWidth - metrics.insets.left - metrics.insets.right + metrics.spacing.width
        return max(1, Int((usable / columnPitch).rounded(.down)))
    }
    var rowCount: Int { itemCount == 0 ? 0 : (itemCount + columns - 1) / columns }

    func rowColumn(of index: Int) -> (row: Int, column: Int) {
        let count = columns
        return (index / count, index % count)
    }

    func index(atRow row: Int, column: Int) -> Int? {
        let count = columns
        guard row >= 0, column >= 0, column < count else { return nil }
        let index = row * count + column
        return index < itemCount ? index : nil
    }

    func frame(forItem index: Int) -> NSRect {
        let (row, column) = rowColumn(of: index)
        return NSRect(x: metrics.insets.left + CGFloat(column) * columnPitch, y: metrics.insets.top + CGFloat(row) * rowPitch,
                      width: metrics.itemSize.width, height: metrics.itemSize.height)
    }

    /// Indexes of the rows that intersect `rect` (whole rows, contiguous).
    func indexes(in rect: NSRect) -> Range<Int> {
        guard itemCount > 0, rowCount > 0 else { return 0..<0 }
        let first = max(0, Int(((rect.minY - metrics.insets.top) / rowPitch).rounded(.down)))
        let last = min(rowCount - 1, Int(((rect.maxY - metrics.insets.top) / rowPitch).rounded(.down)))
        guard first <= last else { return 0..<0 }
        let lower = first * columns
        let upper = min(itemCount, (last + 1) * columns)
        return lower < upper ? lower..<upper : 0..<0
    }

    /// The item under a point, or nil over spacing, insets or past the end.
    func itemIndex(at point: NSPoint) -> Int? {
        guard point.x >= metrics.insets.left, point.y >= metrics.insets.top else { return nil }
        let row = Int(((point.y - metrics.insets.top) / rowPitch).rounded(.down))
        let column = Int(((point.x - metrics.insets.left) / columnPitch).rounded(.down))
        guard let index = index(atRow: row, column: column), frame(forItem: index).contains(point) else { return nil }
        return index
    }

    /// Spatial arrows (§5.5). Left and right wrap across rows; Down from a column with nothing below in the partial
    /// last row lands on the last item.
    func neighbor(of index: Int, _ direction: GridDirection) -> Int? {
        guard index >= 0, index < itemCount else { return nil }
        let (row, column) = rowColumn(of: index)
        switch direction {
        case .left: return index > 0 ? index - 1 : nil
        case .right: return index + 1 < itemCount ? index + 1 : nil
        case .up: return row > 0 ? index - columns : nil
        case .down:
            if let below = self.index(atRow: row + 1, column: column) { return below }
            return row + 1 < rowCount ? itemCount - 1 : nil
        }
    }

    // MARK: NSCollectionViewLayout

    override func prepare() {
        super.prepare()
        if let collectionView, collectionView.numberOfSections > 0 { itemCount = collectionView.numberOfItems(inSection: 0) }
        preparedWidth = availableWidth
    }

    override var collectionViewContentSize: NSSize {
        let rows = CGFloat(rowCount)
        let height = metrics.insets.top + metrics.insets.bottom + rows * rowPitch - (rowCount > 0 ? metrics.spacing.height : 0)
        let minimum = collectionView?.enclosingScrollView?.contentSize.height ?? 0
        return NSSize(width: availableWidth, height: max(height, minimum))
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        indexes(in: rect).compactMap { index in
            let frame = frame(forItem: index)
            return frame.intersects(rect) ? attributes(index, frame) : nil
        }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard indexPath.item >= 0, indexPath.item < itemCount else { return nil }
        return attributes(indexPath.item, frame(forItem: indexPath.item))
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        abs(newBounds.width - preparedWidth) > 0.5
    }

    private func attributes(_ index: Int, _ frame: NSRect) -> NSCollectionViewLayoutAttributes {
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: index, section: 0))
        attributes.frame = frame
        return attributes
    }
}
