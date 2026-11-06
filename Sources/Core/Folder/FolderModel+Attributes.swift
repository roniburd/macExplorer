import Foundation
import MacxFS

/// Extended attributes for the Phase 2 Details columns (P2-15): tags, last opened, permissions, owner and comment.
/// Read on a lane only for the rows a view asks for, cached by identity, and re-read when the watcher reports the
/// item (xattr-only changes leave mtime alone, so the store diff alone would miss them: Review Focus 2). Sorting
/// by one of them reads that one field for every row into the compact sort column only (review fix, §4.4 memory:
/// no full `ExtendedAttributes` per row of a 100k folder).
extension FolderModel {
    /// The attributes loaded so far for the item at `row` (nil until asked for and read). No I/O.
    public func extendedAttributes(atRow row: Int) -> ExtendedAttributes? {
        guard !attributeTable.isEmpty, row >= 0, row < rowCount else { return nil }
        return attributeTable[identity(atRow: row)]
    }

    /// Reads `wanted` for the given model rows (visible rows; not contiguous when grouped) that lack it, then emits
    /// `.extendedAttributes` with the identities whose values changed. Rows outside the folder are ignored. The
    /// request is remembered and re-issued after the watcher invalidates entries or the rows change. At most one
    /// read runs; a request made meanwhile waits, and only the latest one is kept.
    public func requestExtendedAttributes(rows: IndexSet, _ wanted: ExtendedAttributeSet) {
        guard !closed, !wanted.isEmpty else { return }
        let count = rowCount
        let valid = rows.filteredIndexSet { $0 >= 0 && $0 < count }
        lastAttributeRequest = AttributeRequest(rows: valid, wanted: wanted)
        if attributeTask != nil {
            pendingAttributeRequest = lastAttributeRequest
        } else {
            startAttributeRead(AttributeRequest(rows: valid, wanted: wanted))
        }
    }

    /// Every row's value for the sort column (P2-16 sorts by it): the rows lacking it are found off the main actor
    /// (on name-identity volumes each identity normalizes a name), then read in chunks of 2,000 names on `.scan`
    /// lanes, so listing reads are not delayed. After a full invalidation (F5, full rescan) every row is re-read
    /// once. Returns early when the calling task is cancelled, the model closes or a fresh load starts.
    func loadSortColumn() async {
        guard !closed, let field = sortColumnField, field == query.sort.field else { return }
        let refresh = sortColumnRefreshPending
        let store = self.store, column = refresh ? nil : sortColumn, stale = staleSortValues
        let missing = await Task.detached(priority: .userInitiated) {
            Self.rowsLackingSortValue(store, column: column, stale: stale)
        }.value
        guard !Task.isCancelled, !closed, sortColumnField == field else { return }
        let complete = await readSortValues(missing, ExtendedAttributeSet(sortField: field))
        guard complete, sortColumnField == field else { return }
        if refresh { sortColumnRefreshPending = false }
        // Invalidated after their chunk was read (sort-only reads wait for a full re-read): read them now.
        if !staleSortValues.isEmpty { readForSort(Array(staleSortValues.keys)) }
    }

    /// Names and identities of `store` entries that `column` lacks or holds stale (every one without a column). CPU only.
    nonisolated static func rowsLackingSortValue(_ store: EntryStore, column: ExtraColumnValues?,
                                                 stale: [RowID: Int]) -> [(name: String, id: RowID)] {
        var missing: [(name: String, id: RowID)] = []
        for i in 0..<UInt32(store.count) {
            let id = store.identity(i)
            if column?.contains(id) != true || stale[id] != nil { missing.append((store.name(i), id)) }
        }
        return missing
    }

    /// Reads `wanted` (the sort field) for `missing` in chunks of `attributeChunk` on `.scan` lanes; each chunk
    /// goes to the sort column only. Returns false when it stopped early: the calling task was cancelled, the
    /// model closed or a fresh load started.
    @discardableResult
    private func readSortValues(_ missing: [(name: String, id: RowID)], _ wanted: ExtendedAttributeSet) async -> Bool {
        let epoch = self.epoch
        let directory = self.directory, owners = context.ownerNames, volume = openedVolume ?? .unknown
        let lanes = context.lanes
        var start = 0
        while start < missing.count {
            guard !Task.isCancelled, !closed, epoch == self.epoch else { return false }
            let chunk = missing[start..<min(start + Self.attributeChunk, missing.count)]
            start += Self.attributeChunk
            let names = chunk.map(\.name)
            let ids = Dictionary(chunk.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })
            let serial = attributeSerial
            guard let result = try? await lanes.perform(on: volume, .scan, { _ in
                ExtendedAttributeReader.read(names: names, in: directory, wanted: wanted, owners: owners)
            }) else { return false }
            guard !closed, epoch == self.epoch else { return false }
            sortValueReads += names.count
            if adoptSortValues(result, ids: ids, readSerial: serial) { sortValuesChanged() }
        }
        return !Task.isCancelled
    }

    nonisolated static var attributeChunk: Int { 2_000 }

    /// While sorted by an extended field (review fix): reads that field for `ids` lacking it or gone stale, off
    /// screen too, so new rows (patches) and retagged items (watcher invalidations) do not keep a stale position
    /// when no view asked for them. Coalesced per main-actor turn; a changed value schedules the re-sort.
    func readForSort<S: Sequence>(_ ids: S) where S.Element == RowID {
        let field = query.sort.field
        guard field.isExtended, !closed else { return }
        ensureSortColumn(field)
        pendingSortReads.formUnion(ids)
        guard sortReadTask == nil, !pendingSortReads.isEmpty else { return }
        sortReadTask = Task { @MainActor [weak self] in
            await Task.yield()
            while let self, !Task.isCancelled, !self.closed, !self.pendingSortReads.isEmpty {
                let field = self.query.sort.field
                guard field.isExtended, self.sortColumnField == field else { break }
                let ids = self.pendingSortReads, store = self.store
                self.pendingSortReads = []
                // A full re-read of the column is under way (F5, full rescan): it covers these rows (review fix).
                if self.sortColumnRefreshPending && self.extendedSortTask != nil { break }
                var missing: [(name: String, id: RowID)] = []
                for id in ids {
                    guard let index = store.firstIndex(of: id), self.needsSortValue(id) else { continue }
                    missing.append((store.name(index), id))
                }
                await self.readSortValues(missing, ExtendedAttributeSet(sortField: field))
            }
            guard let self, !Task.isCancelled else { return }
            self.sortReadTask = nil
            self.pendingSortReads = []
        }
    }

    func cancelSortReads() {
        sortReadTask?.cancel()
        sortReadTask = nil
        pendingSortReads = []
    }

    // MARK: Reads

    func needsAttributes(_ id: RowID, _ wanted: ExtendedAttributeSet) -> Bool {
        guard let entry = attributeTable[id] else { return true }
        return staleAttributes[id] != nil || !entry.loaded.isSuperset(of: wanted)
    }

    private func startAttributeRead(_ request: AttributeRequest) {
        var names: [String] = []
        var ids: [String: RowID] = [:]
        for row in request.rows where row < rowCount {
            let id = identity(atRow: row)
            guard needsAttributes(id, request.wanted) else { continue }
            let name = name(atRow: row)
            if ids.updateValue(id, forKey: name) == nil { names.append(name) }
        }
        guard !names.isEmpty else { return }
        let toRead = names, directory = self.directory, owners = context.ownerNames, volume = openedVolume ?? .unknown
        let lanes = context.lanes, wanted = request.wanted, epoch = self.epoch, serial = attributeSerial
        attributeTask = Task { @MainActor [weak self] in
            let result = try? await lanes.perform(on: volume, .read) { _ in
                ExtendedAttributeReader.read(names: toRead, in: directory, wanted: wanted, owners: owners)
            }
            guard let self, !self.closed, epoch == self.epoch else { return }   // a fresh load reset the slot
            self.attributeTask = nil
            if let result { self.storeAttributes(result, ids: ids, readSerial: serial) }
            if let next = self.pendingAttributeRequest {
                self.pendingAttributeRequest = nil
                self.startAttributeRead(next)
            }
        }
    }

    /// Adopts a visible-row read that began at `readSerial`. An entry invalidated before the read began is
    /// replaced (fields it does not cover become unloaded and are read on the next request); one invalidated while
    /// it ran stays stale and keeps its value until the follow-up read lands. A read covering the sort field also
    /// updates the sort column; one that does not leaves the row's sort value alone (review fix).
    private func storeAttributes(_ result: [String: ExtendedAttributes], ids: [String: RowID], readSerial: Int) {
        var changed = Set<RowID>()
        let store = self.store
        for (name, attributes) in result {
            guard let id = ids[name], store.firstIndex(of: id) != nil else { continue }
            let old = attributeTable[id]
            let new: ExtendedAttributes
            if let invalidated = staleAttributes[id] {
                guard invalidated <= readSerial else { continue }
                staleAttributes[id] = nil
                new = attributes
            } else {
                new = old.map { $0.merging(attributes) } ?? attributes
            }
            attributeTable[id] = new
            if new != old { changed.insert(id) }
        }
        if !changed.isEmpty { emit(.extendedAttributes(changed)) }
        if adoptSortValues(result, ids: ids, readSerial: readSerial) { sortValuesChanged() }
    }

    // MARK: Invalidation

    /// Watcher events (FolderModel+Watch): the named items' entries, or every entry on a full rescan, go stale.
    func invalidateExtendedAttributes(for event: WatchEvent) {
        guard !attributeTable.isEmpty || sortColumn != nil else { return }
        switch event {
        case .items(let names):
            let store = self.store
            invalidateExtendedAttributes(store.firstIndices(named: names, caseSensitive: caseSensitive).values.map(store.identity))
        case .fullRescan: invalidateAllExtendedAttributes()
        case .rootChanged: break
        }
    }

    /// Rows a patch reported as reloaded (their stat changed) are re-read too.
    func invalidateReloadedAttributes(_ changes: ChangeSet) {
        guard !attributeTable.isEmpty || sortColumn != nil else { return }
        var ids: [RowID] = []
        for case .reload(let rows) in changes.changes {
            for row in rows where row < rowCount { ids.append(identity(atRow: row)) }
        }
        invalidateExtendedAttributes(ids)
    }

    /// F5 and full rescans (both followed by a re-read): the visible entries go stale and are re-read; the sort
    /// column is re-read once, by the `startExtendedSort` that ends the re-read (review fix: not also per row here).
    func invalidateAllExtendedAttributes() {
        if sortColumn != nil { sortColumnRefreshPending = true }
        guard !attributeTable.isEmpty else { return }
        attributeSerial += 1
        for id in attributeTable.keys { staleAttributes[id] = attributeSerial }
        scheduleAttributeRefresh()
    }

    private func invalidateExtendedAttributes(_ ids: [RowID]) {
        guard !ids.isEmpty else { return }
        attributeSerial += 1
        var markedTable = false
        var sortIDs: [RowID] = []
        let column = sortColumn
        for id in ids {
            if attributeTable[id] != nil {
                staleAttributes[id] = attributeSerial
                markedTable = true
            }
            if column?.contains(id) == true {
                staleSortValues[id] = attributeSerial
                sortIDs.append(id)
            }
        }
        if markedTable { scheduleAttributeRefresh() }
        if !sortIDs.isEmpty { readForSort(sortIDs) }
    }

    /// After every store replacement or mutation: the last request is re-checked on the next turn (rows may now
    /// show items without attributes). O(1): entries of items that left go in `pruneAttributes`.
    func storeChangedForAttributes() {
        if lastAttributeRequest != nil { scheduleAttributeRefresh() }
    }

    /// A worker result replaced `old` (review fix: O(diff), not a lookup per cached entry on every patch). Entries
    /// of identities the diff removed or replaced are dropped; an inserted identity that still had an entry (an
    /// item deleted while hidden by the filter, then re-created) loses it so it is read afresh.
    func pruneAttributes(old: EntryStore, diff: DiffResult) {
        guard !attributeTable.isEmpty || !(sortColumn?.isEmpty ?? true) else { return }
        var candidates = diff.replacements.map(\.old)
        if case .remove(let rows)? = diff.changes.changes.first {      // the diff's one remove comes first, in old rows
            for row in rows where row < old.visibleCount { candidates.append(old.identity(old.storageIndex(forRow: row))) }
        }
        let store = self.store
        for id in candidates where store.firstIndex(of: id) == nil { dropAttributes(id) }
        for case .insert(let rows) in diff.changes.changes {
            for row in rows where row < store.visibleCount {
                let id = store.identity(store.storageIndex(forRow: row))
                if attributeTable[id] != nil || sortColumn?.contains(id) == true { dropAttributes(id) }
            }
        }
    }

    private func dropAttributes(_ id: RowID) {
        attributeTable[id] = nil
        staleAttributes[id] = nil
        sortColumn?.remove(id)
        staleSortValues[id] = nil
    }

    /// A fresh load (start, retry): nothing cached survives, and the read in flight is dropped.
    func resetExtendedAttributes() {
        attributeTask?.cancel()
        attributeTask = nil
        pendingAttributeRequest = nil
        attributeTable = [:]
        staleAttributes = [:]
        cancelSortReads()
        dropSortColumn()
    }

    func cancelExtendedAttributes() {
        attributeTask?.cancel()
        attributeTask = nil
        pendingAttributeRequest = nil
        attributeRefreshScheduled = false
    }

    /// Re-issues `lastAttributeRequest` once per main-actor turn, for a complete folder (rows still loading
    /// change every frame, and their reads would queue behind the listing).
    private func scheduleAttributeRefresh() {
        guard !attributeRefreshScheduled, !closed, lastAttributeRequest != nil else { return }
        attributeRefreshScheduled = true
        Task { @MainActor [weak self] in
            guard let self, self.attributeRefreshScheduled else { return }
            self.attributeRefreshScheduled = false
            guard !self.closed, self.state == .complete, let request = self.lastAttributeRequest else { return }
            self.requestExtendedAttributes(rows: request.rows, request.wanted)
        }
    }
}

/// One `requestExtendedAttributes` call: model rows and the attributes wanted for them.
struct AttributeRequest: Equatable {
    var rows: IndexSet
    var wanted: ExtendedAttributeSet
}
