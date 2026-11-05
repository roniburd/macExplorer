import Foundation
import MacxFS

/// LocalChange posts (FileOps, §4.3) and the incremental patch path shared with the watcher (FolderModel+Watch).
extension FolderModel {
    /// Stats every named item and patches the store (also wired automatically through ChangeBus). Posts for
    /// another directory are ignored; posts that arrive while the listing streams are applied once it completes.
    public func applyLocalChange(_ change: LocalChange) {
        guard !closed, ChangeBus.key(for: change.directory) == ChangeBus.key(for: directory) else { return }
        if !change.select.isEmpty { pendingSelect = change.select }
        if let name = change.beginRename { pendingRename = name }
        guard started else { deferredChanges.append(change); return }
        switch state {
        case .complete: enqueuePatch(change.touchedNames, renames: change.renamed)
        case .loading, .partial, .unresponsive, .waitingForPermission: deferredChanges.append(change)
        case .error: break
        }
    }

    /// Applies changes that arrived while the listing streamed, then any pending selection or rename.
    func flushDeferred() {
        let changes = deferredChanges
        deferredChanges = []
        for change in changes { enqueuePatch(change.touchedNames, renames: change.renamed) }
        satisfyPending()
    }

    /// Stats `names` on a lane outside the store queue, then enqueues the CPU-only patch. Results apply in completion
    /// order; for a name that a later-issued read also covers, only that later read's answer is applied.
    /// `then` runs on main after the patch was applied (or dropped for a re-read); never when a fresh load
    /// replaced the epoch.
    func enqueuePatch(_ names: [String], renames: [LocalChange.Rename], then: (@MainActor () -> Void)? = nil) {
        guard !names.isEmpty else { enqueue { [weak self] in self?.satisfyPending(); then?() }; return }
        itemReadSeq += 1
        itemReadsInFlight += 1
        let seq = itemReadSeq, caseSensitive = self.caseSensitive
        for name in names { latestItemRead[NameNormalizer.identityName(name, caseSensitive: caseSensitive)] = seq }
        let epoch = self.epoch, source = itemSource, directory = self.directory, generation = self.generation
        Task { @MainActor [weak self] in
            let result: ItemReadResult?
            do { result = try await source(names, directory, generation) } catch { result = nil }
            guard let self, !self.closed, epoch == self.epoch else { return }
            let superseded = self.claimItemRead(names, seq: seq)
            guard let result else { self.beginReread(); then?(); return }
            if superseded.isEmpty {
                self.enqueuePatchApply(result, names: names, renames: renames, epoch: epoch)
            } else {
                let current = names.filter { !superseded.contains(NameNormalizer.identityName($0, caseSensitive: caseSensitive)) }
                self.enqueuePatchApply(result.dropping(superseded, caseSensitive: caseSensitive), names: current,
                                       renames: renames, epoch: epoch)
            }
            if let then { self.enqueue { then() } }
        }
    }

    /// Identity names of `names` that a newer-issued read also covers (that read answers for them).
    private func claimItemRead(_ names: [String], seq: Int) -> Set<String> {
        itemReadsInFlight -= 1
        var superseded: Set<String> = []
        for name in names {
            let key = NameNormalizer.identityName(name, caseSensitive: caseSensitive)
            if let latest = latestItemRead[key], latest > seq { superseded.insert(key) }
        }
        if itemReadsInFlight == 0 { latestItemRead = [:] }
        return superseded
    }

    private func enqueuePatchApply(_ result: ItemReadResult, names: [String], renames: [LocalChange.Rename], epoch: Int) {
        enqueue { [weak self] in await self?.applyItems(result, names: names, renames: renames, epoch: epoch) }
    }

    /// Watcher incremental path rules (S1 note): rows are deleted only for `missing`, rows named in `errors` are
    /// kept, and a failing readItems falls back to one full re-read.
    private func applyItems(_ result: ItemReadResult, names: [String], renames: [LocalChange.Rename], epoch: Int) async {
        guard !closed, epoch == self.epoch, state == .complete else { return }
        if rereadInFlight { namesPatchedDuringReread.formUnion(names) }
        let old = store, caseSensitive = self.caseSensitive
        let sources = old.firstIndices(named: renames.map(\.from), caseSensitive: caseSensitive)
        let carrying: [(RowID, String)] = renames.compactMap { rename in
            sources[rename.from].map { (old.identity($0), rename.to) }
        }
        let patched = await worker.patch(old, tag: keysTag, result: result, query: query, caseSensitive: caseSensitive,
                                         group: currentGroupSpec(), sizes: sortSizes())
        guard !closed, epoch == self.epoch else { return }
        guard store.version == old.version else { enqueuePatchApply(result, names: names, renames: renames, epoch: epoch); return }
        applyPatch(patched, carrying: carrying)
        satisfyPending()
    }

    /// Selects names posted with `select` and begins the posted inline rename once those items are displayed.
    func satisfyPending() {
        if !pendingSelect.isEmpty {
            // One pass over the store for every pending name (QA round 1: 10k pasted items), not one per name.
            let present = rows(named: pendingSelect)
            if !present.isEmpty { select(.set(present, cursor: nil)) }
        }
        if let name = pendingRename, let row = row(named: name) {
            pendingRename = nil
            emit(.beginRename(row: row))
        }
    }
}

extension ItemReadResult {
    /// The result without the given identity names (their newer read answers for them).
    func dropping(_ identityNames: Set<String>, caseSensitive: Bool) -> ItemReadResult {
        func kept(_ name: String) -> Bool { !identityNames.contains(NameNormalizer.identityName(name, caseSensitive: caseSensitive)) }
        var filtered = Batch(generation: batch.generation)
        for i in 0..<batch.count {
            let name = batch.name(at: i)
            guard kept(name) else { continue }
            let entry = batch.entries[i]
            Array(name.utf8).withUnsafeBufferPointer { filtered.append(entry, nameBytes: $0) }
            for error in batch.errors where Int(error.index) == i {
                filtered.errors.append(EntryError(index: UInt32(filtered.count - 1), code: error.code))
            }
        }
        var result = self
        result.batch = filtered
        result.missing = missing.filter(kept)
        result.errors = errors.filter { kept($0.key) }
        return result
    }
}
