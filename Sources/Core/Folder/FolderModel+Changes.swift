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

    /// Re-reads the names `change` touches and runs `then` on main once the store holds the final answer for them:
    /// every item read covering those names was applied (or dropped for a newer one) and no coalesced watcher event
    /// still names them. Reads of the same names apply in completion order and the watcher can split a rename into
    /// its two names, issuing the second read only after the first applied, so the listing may briefly show the old
    /// name gone before the new one appears; "the read issued last" is not enough, the wait is on all of them.
    /// `then` never runs once the model closed or a fresh load replaced the epoch.
    public func reconcile(_ change: LocalChange, then: @escaping @MainActor () -> Void) {
        guard !closed, ChangeBus.key(for: change.directory) == ChangeBus.key(for: directory) else { return }
        let caseSensitive = self.caseSensitive
        enqueuePatch(change.touchedNames, renames: change.renamed)
        settleWaiters.append((Set(change.touchedNames.map { NameNormalizer.identityName($0, caseSensitive: caseSensitive) }), then))
        runSettledWaiters()
    }

    /// One read covering `keys` (identity names) was applied, dropped or superseded.
    func settleItemReads(_ keys: some Sequence<String>) {
        for key in keys {
            guard let count = unappliedItemReads[key] else { continue }
            unappliedItemReads[key] = count > 1 ? count - 1 : nil
        }
        runSettledWaiters()
    }

    /// Runs the `reconcile` callbacks whose names no read in flight and no coalesced watcher event covers.
    func runSettledWaiters() {
        guard !settleWaiters.isEmpty else { return }
        let caseSensitive = self.caseSensitive
        let watched = Set(watchPending.names.map { NameNormalizer.identityName($0, caseSensitive: caseSensitive) })
        var ready: [@MainActor () -> Void] = []
        settleWaiters.removeAll { waiter in
            let settled = waiter.names.allSatisfy { unappliedItemReads[$0] == nil && !watched.contains($0) }
            if settled { ready.append(waiter.then) }
            return settled
        }
        for then in ready { then() }
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
    /// A read that covers one side of a rename whose read is not applied yet covers both sides and carries the
    /// rename, so the two names always change in one patch (see `coveringUnappliedRenames`).
    /// `then` runs on main after the patch is in the store (also after a retry because the store changed during
    /// the patch), or once the read failed and a re-read began; never when a fresh load replaced the epoch.
    func enqueuePatch(_ requested: [String], renames requestedRenames: [LocalChange.Rename],
                      then: (@MainActor () -> Void)? = nil) {
        guard !requested.isEmpty else { enqueue { [weak self] in self?.satisfyPending(); then?() }; return }
        let (names, renames) = coveringUnappliedRenames(requested, requestedRenames)
        itemReadSeq += 1
        itemReadsInFlight += 1
        let seq = itemReadSeq, caseSensitive = self.caseSensitive
        for name in names {
            let key = NameNormalizer.identityName(name, caseSensitive: caseSensitive)
            latestItemRead[key] = seq
            unappliedItemReads[key, default: 0] += 1
        }
        if !renames.isEmpty { unappliedRenames[seq] = renames }
        let epoch = self.epoch, source = itemSource, directory = self.directory, generation = self.generation
        Task { @MainActor [weak self] in
            let result: ItemReadResult?
            do { result = try await source(names, directory, generation) } catch { result = nil }
            guard let self, !self.closed, epoch == self.epoch else { return }
            let superseded = self.claimItemRead(names, seq: seq)
            guard let result else {
                self.unappliedRenames[seq] = nil
                self.beginReread()
                self.settleItemReads(names.map { NameNormalizer.identityName($0, caseSensitive: caseSensitive) })
                then?()
                return
            }
            if superseded.isEmpty {
                self.enqueuePatchApply(result, names: names, renames: renames, epoch: epoch, seq: seq, then: then)
            } else {
                self.settleItemReads(superseded)
                let current = names.filter { !superseded.contains(NameNormalizer.identityName($0, caseSensitive: caseSensitive)) }
                self.enqueuePatchApply(result.dropping(superseded, caseSensitive: caseSensitive), names: current,
                                       renames: renames, epoch: epoch, seq: seq, then: then)
            }
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

    /// The watcher can deliver a rename's two names separately and read the old name alone after the rename post's
    /// read was issued. That read answers for the old name first: the row vanished before the new name was listed,
    /// and its identity (selection, an open rename field) was lost. So a read touching either side of a rename whose
    /// read is still unapplied also reads the other side and carries the rename itself.
    private func coveringUnappliedRenames(_ names: [String], _ renames: [LocalChange.Rename])
        -> (names: [String], renames: [LocalChange.Rename]) {
        guard !unappliedRenames.isEmpty else { return (names, renames) }
        let caseSensitive = self.caseSensitive
        func key(_ name: String) -> String { NameNormalizer.identityName(name, caseSensitive: caseSensitive) }
        var names = names, renames = renames
        var keys = Set(names.map(key))
        let pending = unappliedRenames.sorted { $0.key < $1.key }.flatMap(\.value)
        for rename in pending where keys.contains(key(rename.from)) || keys.contains(key(rename.to)) {
            if !renames.contains(rename) { renames.append(rename) }
            for name in [rename.from, rename.to] where keys.insert(key(name)).inserted { names.append(name) }
        }
        return (names, renames)
    }

    private func enqueuePatchApply(_ result: ItemReadResult, names: [String], renames: [LocalChange.Rename], epoch: Int,
                                   seq: Int, then: (@MainActor () -> Void)?) {
        enqueue { [weak self] in
            await self?.applyItems(result, names: names, renames: renames, epoch: epoch, seq: seq, then: then)
        }
    }

    /// Watcher incremental path rules (S1 note): rows are deleted only for `missing`, rows named in `errors` are
    /// kept, and a failing readItems falls back to one full re-read.
    private func applyItems(_ result: ItemReadResult, names: [String], renames: [LocalChange.Rename], epoch: Int,
                            seq: Int, then: (@MainActor () -> Void)?) async {
        guard !closed, epoch == self.epoch else { return }
        let caseSensitive = self.caseSensitive
        let keys = names.map { NameNormalizer.identityName($0, caseSensitive: caseSensitive) }
        guard state == .complete else {
            unappliedRenames[seq] = nil
            settleItemReads(keys)
            then?()
            return
        }
        if rereadInFlight { namesPatchedDuringReread.formUnion(names) }
        let old = store
        let sources = old.firstIndices(named: renames.map(\.from), caseSensitive: caseSensitive)
        let carrying: [(RowID, String)] = renames.compactMap { rename in
            sources[rename.from].map { (old.identity($0), rename.to) }
        }
        let patched = await worker.patch(old, tag: keysTag, result: result, query: query, caseSensitive: caseSensitive)
        guard !closed, epoch == self.epoch else { return }
        guard store.version == old.version else {
            enqueuePatchApply(result, names: names, renames: renames, epoch: epoch, seq: seq, then: then)
            return
        }
        unappliedRenames[seq] = nil
        applyPatch(patched, carrying: carrying)
        satisfyPending()
        settleItemReads(keys)
        then?()
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
