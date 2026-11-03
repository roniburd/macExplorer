import Foundation
import MacxFS

/// LocalChange posts (FileOps, §4.3) and the minimal watcher hookup (P1-11 replaces handleWatch with the
/// buffered, classified path in FolderModel+Watch.swift).
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

    /// Minimal P1-10 handling: names → incremental patch, rescan → full re-read. Root changes are P1-11's.
    func handleWatch(_ event: WatchEvent) {
        guard !closed else { return }
        switch event {
        case .items(let names):
            if state == .complete {
                enqueuePatch(names, renames: [])
            } else {
                deferredChanges.append(LocalChange(directory: directory, modified: names))
            }
        case .fullRescan:
            beginReread()
        case .rootChanged:
            break
        }
    }

    /// Applies changes that arrived while the listing streamed, then any pending selection or rename.
    func flushDeferred() {
        let changes = deferredChanges
        deferredChanges = []
        for change in changes { enqueuePatch(change.touchedNames, renames: change.renamed) }
        satisfyPending()
    }

    func enqueuePatch(_ names: [String], renames: [LocalChange.Rename]) {
        enqueue { [weak self] in await self?.patchNow(names, renames: renames) }
    }

    /// Watcher incremental path rules (S1 note): rows are deleted only for `missing`, rows named in `errors` are
    /// kept, and a failing readItems falls back to one full re-read.
    private func patchNow(_ names: [String], renames: [LocalChange.Rename]) async {
        guard !names.isEmpty else { satisfyPending(); return }
        let epoch = self.epoch
        let result: ItemReadResult
        do {
            result = try await itemSource(names, directory, generation)
        } catch {
            guard !closed, epoch == self.epoch else { return }
            beginReread()
            return
        }
        guard !closed, epoch == self.epoch, state == .complete else { return }
        if rereadInFlight { namesPatchedDuringReread.formUnion(names) }
        let old = store, caseSensitive = self.caseSensitive
        let carrying: [(RowID, String)] = renames.compactMap { rename in
            old.firstIndex(named: rename.from, caseSensitive: caseSensitive).map { (old.identity($0), rename.to) }
        }
        let patched = await worker.patch(old, tag: keysTag, result: result, query: query, caseSensitive: caseSensitive)
        guard !closed, epoch == self.epoch else { return }
        guard store.version == old.version else { enqueuePatch(names, renames: renames); return }
        applyPatch(patched, carrying: carrying)
        satisfyPending()
    }

    /// Selects names posted with `select` and begins the posted inline rename once those items are displayed.
    func satisfyPending() {
        if !pendingSelect.isEmpty {
            let present = pendingSelect.filter { row(named: $0) != nil }
            if !present.isEmpty { select(.names(present)) }
        }
        if let name = pendingRename, let row = row(named: name) {
            pendingRename = nil
            emit(.beginRename(row: row))
        }
    }
}
