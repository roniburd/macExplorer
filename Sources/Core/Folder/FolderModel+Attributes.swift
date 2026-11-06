import Foundation
import MacxFS

/// Extended attributes for the Phase 2 Details columns (P2-15): tags, last opened, permissions, owner and comment.
/// Read on a lane only for the rows a view asks for (or every row, before sorting by one of them), cached by
/// identity, and re-read when the watcher reports the item (xattr-only changes leave mtime alone, so the store diff
/// alone would miss them: Review Focus 2).
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

    /// Every row's `wanted` attributes (P2-16 sorts by them): chunks of 2,000 names on `.scan` lanes, so listing
    /// reads are not delayed. Returns early when the calling task is cancelled, the model closes or a fresh load
    /// starts.
    func loadAllExtendedAttributes(_ wanted: ExtendedAttributeSet) async {
        guard !closed, !wanted.isEmpty else { return }
        var missing: [(name: String, id: RowID)] = []
        for row in 0..<rowCount {
            let id = identity(atRow: row)
            if needsAttributes(id, wanted) { missing.append((name(atRow: row), id)) }
        }
        await readAttributes(missing, wanted)
    }

    /// Reads `wanted` for `missing` in chunks of `attributeChunk` on `.scan` lanes and stores each chunk. Returns
    /// early when the calling task is cancelled, the model closes or a fresh load starts.
    private func readAttributes(_ missing: [(name: String, id: RowID)], _ wanted: ExtendedAttributeSet) async {
        let epoch = self.epoch
        let directory = self.directory, owners = context.ownerNames, volume = openedVolume ?? .unknown
        let lanes = context.lanes
        var start = 0
        while start < missing.count {
            guard !Task.isCancelled, !closed, epoch == self.epoch else { return }
            let chunk = missing[start..<min(start + Self.attributeChunk, missing.count)]
            start += Self.attributeChunk
            let names = chunk.map(\.name)
            let ids = Dictionary(chunk.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })
            let serial = attributeSerial
            guard let result = try? await lanes.perform(on: volume, .scan, { _ in
                ExtendedAttributeReader.read(names: names, in: directory, wanted: wanted, owners: owners)
            }) else { return }
            guard !closed, epoch == self.epoch else { return }
            storeAttributes(result, ids: ids, readSerial: serial)
        }
    }

    nonisolated static var attributeChunk: Int { 2_000 }

    /// While sorted by an extended field (review fix): reads that field for `ids` lacking it or gone stale, off
    /// screen too, so new rows (patches) and retagged items (watcher invalidations) do not keep a stale position
    /// when no view asked for them. Coalesced per main-actor turn; `storeAttributes` then schedules the re-sort.
    func readForSort<S: Sequence>(_ ids: S) where S.Element == RowID {
        guard query.sort.field.isExtended, !closed else { return }
        pendingSortReads.formUnion(ids)
        guard sortReadTask == nil, !pendingSortReads.isEmpty else { return }
        sortReadTask = Task { @MainActor [weak self] in
            await Task.yield()
            while let self, !Task.isCancelled, !self.closed, !self.pendingSortReads.isEmpty {
                let field = self.query.sort.field
                guard field.isExtended else { break }
                let wanted = ExtendedAttributeSet(sortField: field), ids = self.pendingSortReads, store = self.store
                self.pendingSortReads = []
                var missing: [(name: String, id: RowID)] = []
                for id in ids {
                    guard let index = store.firstIndex(of: id), self.needsAttributes(id, wanted) else { continue }
                    missing.append((store.name(index), id))
                }
                await self.readAttributes(missing, wanted)
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

    /// Adopts a read that began at `readSerial`. An entry invalidated before the read began is replaced (fields
    /// it does not cover become unloaded and are read on the next request); one invalidated while it ran stays
    /// stale and keeps its value until the follow-up read lands.
    private func storeAttributes(_ result: [String: ExtendedAttributes], ids: [String: RowID], readSerial: Int) {
        var changed = Set<RowID>()
        var before: [RowID: ExtendedAttributes?] = [:], after: [RowID: ExtendedAttributes] = [:]
        let tracksSort = query.sort.field.isExtended
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
            if new != old {
                changed.insert(id)
                updateSortColumn(id, new)
                if tracksSort { before[id] = old; after[id] = new }
            }
        }
        if !changed.isEmpty { emit(.extendedAttributes(changed)) }
        if !after.isEmpty { attributesChangedForSort(old: before, new: after) }
    }

    // MARK: Invalidation

    /// Watcher events (FolderModel+Watch): the named items' entries, or every entry on a full rescan, go stale.
    func invalidateExtendedAttributes(for event: WatchEvent) {
        guard !attributeTable.isEmpty else { return }
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
        guard !attributeTable.isEmpty else { return }
        var ids: [RowID] = []
        for case .reload(let rows) in changes.changes {
            for row in rows where row < rowCount { ids.append(identity(atRow: row)) }
        }
        invalidateExtendedAttributes(ids)
    }

    func invalidateAllExtendedAttributes() {
        invalidateExtendedAttributes(Array(attributeTable.keys))
    }

    private func invalidateExtendedAttributes(_ ids: [RowID]) {
        guard !ids.isEmpty else { return }
        attributeSerial += 1
        var marked: [RowID] = []
        for id in ids where attributeTable[id] != nil {
            staleAttributes[id] = attributeSerial
            marked.append(id)
        }
        guard !marked.isEmpty else { return }
        scheduleAttributeRefresh()
        if query.sort.field.isExtended { readForSort(marked) }
    }

    /// After every store replacement or mutation: entries of items that left the store are dropped, and the last
    /// request is re-checked on the next turn (rows may now show items without attributes).
    func storeChangedForAttributes() {
        if !attributeTable.isEmpty {
            let store = self.store
            let gone = attributeTable.keys.filter { store.firstIndex(of: $0) == nil }
            for id in gone {
                attributeTable[id] = nil
                staleAttributes[id] = nil
                sortIntegers[id] = nil
                sortKeys[id] = nil
            }
        }
        if lastAttributeRequest != nil { scheduleAttributeRefresh() }
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
