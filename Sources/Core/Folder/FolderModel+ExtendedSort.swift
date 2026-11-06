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
    /// O(1) for an extended field once its column is built: the column is shared copy-on-write.
    func sortValues() -> SortValues {
        let field = query.sort.field
        if field == .size { return SortValues(sizes: sortSizes()) }
        guard field.isExtended else { return .none }
        ensureSortColumn(field)
        guard let column = sortColumn, !column.isEmpty else { return .none }
        return SortValues(column: column)
    }

    /// Builds the sort column for `field` if it is not the one kept (once per sort change), seeded from the
    /// visible rows' attributes that already hold it.
    func ensureSortColumn(_ field: SortField) {
        guard sortColumnField != field else { return }
        dropSortColumn()
        guard field.isExtended else { return }
        sortColumnField = field
        sortColumnBuilds += 1
        var column = ExtraColumnValues(kind: Self.columnKind(field))
        let wanted = ExtendedAttributeSet(sortField: field)
        for (id, attributes) in attributeTable where staleAttributes[id] == nil && attributes.loaded.isSuperset(of: wanted) {
            Self.setSortValue(&column, id, attributes, field: field)
        }
        sortColumn = column
    }

    func dropSortColumn() {
        sortColumnField = nil
        sortColumn = nil
        staleSortValues = [:]
        sortColumnRefreshPending = false
    }

    /// Whether `id`'s value for the sort column must be (re-)read.
    func needsSortValue(_ id: RowID) -> Bool {
        guard let column = sortColumn else { return false }
        return !column.contains(id) || staleSortValues[id] != nil
    }

    /// Adopts the sort field's values from a read that began at `readSerial` (reads that did not cover the field
    /// leave the column alone, so a row never loses its position to a narrower read). Returns whether a value the
    /// sort uses changed.
    func adoptSortValues(_ result: [String: ExtendedAttributes], ids: [String: RowID], readSerial: Int) -> Bool {
        guard let field = sortColumnField, field == query.sort.field, sortColumn != nil else { return false }
        let wanted = ExtendedAttributeSet(sortField: field)
        let store = self.store
        var changed = false
        for (name, attributes) in result where attributes.loaded.isSuperset(of: wanted) {
            guard let id = ids[name], store.firstIndex(of: id) != nil else { continue }
            if let invalidated = staleSortValues[id] {
                guard invalidated <= readSerial else { continue }      // invalidated while the read ran
                staleSortValues[id] = nil
            }
            if Self.setSortValue(&sortColumn!, id, attributes, field: field) { changed = true }
        }
        return changed
    }

    nonisolated static func columnKind(_ field: SortField) -> ExtraColumnValues.Kind {
        switch field {
        case .dateLastOpened, .permissions: .integers
        default: .strings
        }
    }

    /// Per the P2-16 rules: integers for Last Opened (ns) and Permissions (`mode & 0o7777`); `SortKeys.nameKey`
    /// bytes for Tags (first tag), Owner and Comments. Absent values are recorded as loaded without a value (they
    /// sort last). Returns whether the value changed.
    @discardableResult
    nonisolated static func setSortValue(_ column: inout ExtraColumnValues, _ id: RowID, _ attributes: ExtendedAttributes,
                                         field: SortField) -> Bool {
        switch column.kind {
        case .integers: column.set(id, integer: integerValue(attributes, field: field))
        case .strings: column.set(id, key: stringValue(attributes, field: field).map { SortKeys.nameKey($0, isFolder: false) })
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

    /// Whether the values for an extended sort are still loading (the re-sort follows the load).
    public var extendedSortLoading: Bool { extendedSortTask != nil }

    /// For an extended sort field of a complete folder: loads that field for every row that lacks it (every row
    /// after a full invalidation: F5, full rescan), then re-sorts if `query` is still the model's query. Cancels the
    /// previous such load. Other fields only cancel it.
    func startExtendedSort() {
        extendedSortTask?.cancel()
        extendedSortTask = nil
        columnResortTask?.cancel()
        columnResortTask = nil
        let wanted = query
        guard wanted.sort.field.isExtended, state == .complete, !closed else { return }
        ensureSortColumn(wanted.sort.field)             // kept current by the reads below
        extendedSortTask = Task { @MainActor [weak self] in
            await self?.loadSortColumn()
            guard let self, !Task.isCancelled else { return }
            self.extendedSortTask = nil
            guard !self.closed, self.query == wanted else { return }
            self.enqueue { [weak self] in await self?.resortNow() }
        }
    }

    /// Values read for the sort column changed while sorted by an extended field (visible-row reads, watcher
    /// re-reads): one coalesced re-sort. Not while `startExtendedSort` loads (it re-sorts at the end).
    func sortValuesChanged() {
        guard query.sort.field.isExtended, extendedSortTask == nil, state == .complete, !closed else { return }
        scheduleColumnResort()
    }

    func cancelExtendedSort() {
        extendedSortTask?.cancel()
        extendedSortTask = nil
        columnResortTask?.cancel()
        columnResortTask = nil
        cancelSortReads()
    }

    /// The sort left an extended field (review fix, §4.4 memory): the sort column goes, and the attributes kept
    /// for display shrink to the rows the view last asked for (they are on screen).
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
