import Foundation
import MacxFS

/// Sorting by an extended column (P2-16): Tags, Date Last Opened, Permissions, Owner, Comments.
///
/// `setQuery` emits `.query` at once (the header indicator moves), then `startExtendedSort` loads the field for every
/// row on `.scan` lanes and, if the query is still current, re-sorts once. Rows keep their previous order until then;
/// a newer `setQuery` cancels the load. Values reach the worker keyed by identity (`SortValues`), and the worker maps
/// them to its own store's indices, so every sort path (re-sort, patch, re-read, finished load) uses them.
extension FolderModel {
    /// Folder sizes and the extended column's values, by identity, for the worker (empty unless the sort needs them).
    func sortValues() -> SortValues {
        let field = query.sort.field
        if field == .size { return SortValues(sizes: sortSizes()) }
        guard field.isExtended, !attributeTable.isEmpty else { return .none }
        return SortValues(column: Self.columnValues(attributeTable, field: field))
    }

    /// Per the P2-16 rules: integers for Last Opened (ns) and Permissions (`mode & 0o7777`); `SortKeys.nameKey`
    /// bytes for Tags (first tag), Owner and Comments. Unloaded or absent values are left out (they sort last).
    nonisolated static func columnValues(_ table: [RowID: ExtendedAttributes], field: SortField) -> ExtraColumnValues? {
        switch field {
        case .dateLastOpened, .permissions:
            var values: [RowID: Int64] = [:]
            values.reserveCapacity(table.count)
            for (id, attributes) in table {
                if let value = integerValue(attributes, field: field) { values[id] = value }
            }
            return .integers(values)
        case .tags, .owner, .comments:
            var keys: [RowID: [UInt8]] = [:]
            keys.reserveCapacity(table.count)
            for (id, attributes) in table {
                if let text = stringValue(attributes, field: field) { keys[id] = SortKeys.nameKey(text, isFolder: false) }
            }
            return .strings(keys)
        default:
            return nil
        }
    }

    nonisolated static func integerValue(_ a: ExtendedAttributes, field: SortField) -> Int64? {
        switch field {
        case .dateLastOpened:
            guard a.loaded.contains(.lastOpened), let date = a.lastOpened else { return nil }
            return Int64((date.timeIntervalSince1970 * 1e9).rounded())
        case .permissions:
            guard a.loaded.contains(.permissions), let mode = a.mode else { return nil }
            return Int64(mode & 0o7777)
        default: return nil
        }
    }

    nonisolated static func stringValue(_ a: ExtendedAttributes, field: SortField) -> String? {
        switch field {
        case .tags: return a.loaded.contains(.tags) ? a.tags.first : nil
        case .owner:
            guard a.loaded.contains(.owner) else { return nil }
            return a.ownerName ?? a.ownerID.map(String.init)
        case .comments:
            guard a.loaded.contains(.comments), let comment = a.comment, !comment.isEmpty else { return nil }
            return comment
        default: return nil
        }
    }

    /// Whether the value `field` sorts by differs between two entries of one item.
    nonisolated static func sortValueChanged(_ old: ExtendedAttributes?, _ new: ExtendedAttributes, field: SortField) -> Bool {
        switch field {
        case .dateLastOpened, .permissions:
            return old.flatMap { integerValue($0, field: field) } != integerValue(new, field: field)
        default:
            return old.flatMap { stringValue($0, field: field) } != stringValue(new, field: field)
        }
    }

    /// For an extended sort field of a complete folder: loads that field for every row, then re-sorts if `query` is
    /// still the model's query. Cancels the previous such load. Other fields only cancel it.
    func startExtendedSort() {
        extendedSortTask?.cancel()
        extendedSortTask = nil
        columnResortTask?.cancel()
        columnResortTask = nil
        let wanted = query
        guard wanted.sort.field.isExtended, state == .complete, !closed else { return }
        extendedSortTask = Task { @MainActor [weak self] in
            await self?.loadAllExtendedAttributes(ExtendedAttributeSet(sortField: wanted.sort.field))
            guard let self, !Task.isCancelled else { return }
            self.extendedSortTask = nil
            guard !self.closed, self.query == wanted else { return }
            self.enqueue { [weak self] in await self?.resortNow() }
        }
    }

    /// Attributes read for `changed` items while sorted by an extended field (visible-row reads, watcher re-reads):
    /// one coalesced re-sort when a sort value changed. Not while `startExtendedSort` loads (it re-sorts at the end).
    func attributesChangedForSort(old: [RowID: ExtendedAttributes?], new: [RowID: ExtendedAttributes]) {
        let field = query.sort.field
        guard field.isExtended, extendedSortTask == nil, state == .complete, !closed,
              new.contains(where: { Self.sortValueChanged(old[$0.key] ?? nil, $0.value, field: field) }) else { return }
        scheduleColumnResort()
    }

    func cancelExtendedSort() {
        extendedSortTask?.cancel()
        extendedSortTask = nil
        columnResortTask?.cancel()
        columnResortTask = nil
    }

    private func scheduleColumnResort() {
        guard columnResortTask == nil else { return }
        let delay = context.resortCoalescing
        columnResortTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) } else { await Task.yield() }
            guard let self, !Task.isCancelled else { return }
            self.columnResortTask = nil
            guard !self.closed, self.state == .complete, self.query.sort.field.isExtended else { return }
            self.enqueue { [weak self] in await self?.resortNow() }
        }
    }
}

/// Sort inputs main hands the folder worker, keyed by identity (P2-13/P2-14 notes): computed folder sizes for the
/// size sort and the extended column's values for an extended sort.
struct SortValues: Sendable {
    var sizes: [RowID: Int64] = [:]
    var column: ExtraColumnValues?

    static let none = SortValues()

    /// The storage-index form for `store` (the store the worker is sorting).
    func extras(for query: ViewQuery, in store: EntryStore) -> SortExtras {
        SortExtras.make(sizes: query.sort.field == .size ? sizes : [:],
                        column: query.sort.field.isExtended ? column : nil, in: store)
    }

    var isEmpty: Bool { sizes.isEmpty && column == nil }
}
