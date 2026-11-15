import AppKit
import Core
import MacxFS

/// Scenario probes (ScenarioHooks.thumbnailNames, iconsVisibleNames).
extension IconsViewController {
    /// Scenario hook `thumbnailNames`: the visible items whose cell shows a cached thumbnail, in grid order.
    func thumbnailNames() -> [String] {
        guard let source else { return [] }
        return collectionView.visibleItems().compactMap { item -> (Int, String)? in
            guard let item = item as? IconItem, let key = item.thumbnailKey, context.thumbnails.image(key) != nil,
                  let row = collectionView.indexPath(for: item)?.item, row < source.rowCount else { return nil }
            return (row, source.name(atRow: row))
        }.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// Scenario hook `iconsVisibleNames`: the items in the visible rect, in grid order (geometry only).
    func visibleNames() -> [String] {
        guard let source else { return [] }
        return visibleRows().filter { $0 < source.rowCount }.map { source.name(atRow: $0) }
    }
}
