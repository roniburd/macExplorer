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
    /// O(1) for an extended field once its column is built: the cached dictionaries are shared copy-on-write.
    func sortValues() -> SortValues {
        let field = query.sort.field
        if field == .size { return SortValues(sizes: sortSizes()) }
        guard field.isExtended else { return .none }
        ensureSortColumn(field)
        switch field {
        case .dateLastOpened, .permissions: return sortIntegers.isEmpty ? .none : SortValues(column: .integers(sortIntegers))
        default: return sortKeys.isEmpty ? .none : SortValues(column: .strings(sortKeys))
        }
    }

    /// Builds the sort column for `field` from `attributeTable` if it is not the one kept (once per sort change;
    /// `startExtendedSort` builds it before loading, while the table holds visible rows at most).
    func ensureSortColumn(_ field: SortField) {
        guard sortColumnField != field else { return }
        dropSortColumn()
        sortColumnField = field
        sortColumnBuilds += 1
        switch Self.columnValues(attributeTable, field: field) {
        case .integers(let values)?: sortIntegers = values
        case .strings(let keys)?: sortKeys = keys
        case nil: break
        }
    }

    /// Keeps the sort column current for one identity whose attributes changed (nil: it left the table).
    func updateSortColumn(_ id: RowID, _ attributes: ExtendedAttributes?) {
        guard let field = sortColumnField else { return }
        switch field {
        case .dateLastOpened, .permissions:
            sortIntegers[id] = attributes.flatMap { Self.integerValue($0, field: field) }
        default:
            sortKeys[id] = attributes.flatMap { Self.stringValue($0, field: field) }.map { SortKeys.nameKey($0, isFolder: false) }
        }
    }

    func dropSortColumn() {
        sortColumnField = nil
        sortIntegers = [:]
        sortKeys = [:]
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
        case .tags:
            guard a.loaded.contains(.tags), let tag = a.tags.first, !tag.isEmpty else { return nil }
            return tag
        case .owner:
            guard a.loaded.contains(.owner), let owner = a.ownerName ?? a.ownerID.map(String.init), !owner.isEmpty else { return nil }
            return owner
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
        ensureSortColumn(wanted.sort.field)             // kept current by the reads below
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
        cancelSortReads()
    }

    /// The sort left an extended field (review fix, §4.4 memory): the per-row values loaded for it go, except the
    /// rows the view last asked for (they are on screen); the sort column is dropped.
    func trimAttributesAfterExtendedSort() {
        dropSortColumn()
        guard !attributeTable.isEmpty else { return }
        var keep = Set<RowID>()
        if let request = lastAttributeRequest {
            let count = rowCount
            for row in request.rows where row < count { keep.insert(identity(atRow: row)) }
        }
        attributeTable = attributeTable.filter { keep.contains($0.key) }
        if !staleAttributes.isEmpty { staleAttributes = staleAttributes.filter { keep.contains($0.key) } }
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
