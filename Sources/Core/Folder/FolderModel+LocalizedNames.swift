import Foundation
import MacxFS

/// Finder localized display names (design 2026-11-05 §1). Only a bounded set of candidates is looked up (app bundles,
/// "*.localized" folders, folders of a few system locations), off main, after the listing is complete; the first frame
/// never waits. Results are cached by real name for the model's life (refresh clears it) and applied as one re-sort.
extension FolderModel {
    /// Parents whose sub-folders Finder localizes ("Applications", "Library", "Users", "Documents", …).
    nonisolated static func localizesSubfolders(_ directory: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        func trimmed(_ url: URL) -> String {
            let p = url.standardizedFileURL.path(percentEncoded: false)
            return p.count > 1 && p.hasSuffix("/") ? String(p.dropLast()) : p
        }
        let p = trimmed(directory), h = trimmed(home)
        return ["/", "/System", "/System/Library", "/Users", "/Library", h, h + "/Library"].contains(p)
    }

    /// Whether the item at `index` may have a localized name worth looking up.
    nonisolated static func isLocalizationCandidate(_ store: EntryStore, _ index: UInt32, subfolders: Bool) -> Bool {
        // Byte suffix checks: this runs over every row after each patch, so no String per row.
        switch store.entry(index).kind {
        case .package:
            return store.withNameBytes(index) { hasSuffix($0, appSuffix, caseInsensitive: true) }
        case .directory:
            return subfolders || store.withNameBytes(index) { hasSuffix($0, localizedSuffix, caseInsensitive: false) }
        default:
            return false
        }
    }

    private nonisolated static let appSuffix: [UInt8] = Array(".app".utf8)
    private nonisolated static let localizedSuffix: [UInt8] = Array(".localized".utf8)

    private nonisolated static func hasSuffix(_ name: UnsafeBufferPointer<UInt8>, _ suffix: [UInt8], caseInsensitive: Bool) -> Bool {
        guard name.count > suffix.count else { return false }
        let start = name.count - suffix.count
        for (i, byte) in suffix.enumerated() {
            let b = name[start + i]
            if b != byte && !(caseInsensitive && b | 0x20 == byte) { return false }
        }
        return true
    }

    /// The stem to show for `name` given Finder's localized name, or "" when it adds nothing.
    nonisolated static func localizedStem(realName name: String, localized: String) -> String {
        let realStem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var stem = localized
        if !ext.isEmpty, stem.lowercased().hasSuffix("." + ext.lowercased()) { stem = String(stem.dropLast(ext.count + 1)) }
        if name.hasSuffix(".localized") { return stem.isEmpty ? realStem : stem }   // always hide ".localized"
        return stem.isEmpty || stem == realStem || stem == name ? "" : stem
    }

    /// Off main: (identity, real name, stem) per item, "" when Finder's name adds nothing.
    nonisolated static func resolveLocalizedStems(_ directory: URL, _ items: [(RowID, String)]) -> [(RowID, String, String)] {
        var out: [(RowID, String, String)] = []
        for (id, name) in items {
            if Task.isCancelled { break }
            let url = directory.appending(path: name, directoryHint: .isDirectory)
            let localized = (try? url.resourceValues(forKeys: [.localizedNameKey]))?.localizedName ?? ""
            out.append((id, name, localizedStem(realName: name, localized: localized)))
        }
        return out
    }

    func scheduleLocalizedNames() {
        guard !closed, state == .complete, volume?.isLocal ?? false else { return }
        let subfolders = Self.localizesSubfolders(directory)
        var known: [RowID: String] = [:]
        var unknown: [(RowID, String)] = []
        for i in 0..<UInt32(store.count) where Self.isLocalizationCandidate(store, i, subfolders: subfolders) {
            let name = store.name(i)
            if let stem = localizedNameCache[name] {
                if (store.localizedStem(i) ?? "") != stem { known[store.identity(i)] = stem }
            } else {
                unknown.append((store.identity(i), name))
            }
        }
        if !known.isEmpty { enqueueLocalizedStems(known) }
        guard !unknown.isEmpty, localizedNamesTask == nil else { return }
        let directory = self.directory
        localizedNamesTask = Task { [weak self] in
            let items = unknown
            let resolved = await Task.detached(priority: .utility) { FolderModel.resolveLocalizedStems(directory, items) }.value
            guard let self, !self.closed, !Task.isCancelled else { return }
            self.localizedNamesTask = nil
            var stems: [RowID: String] = [:]
            for (id, name, stem) in resolved {
                self.localizedNameCache[name] = stem
                stems[id] = stem
            }
            self.enqueueLocalizedStems(stems)
            self.scheduleLocalizedNames()   // candidates that appeared while this lookup ran
        }
    }

    private func enqueueLocalizedStems(_ stems: [RowID: String]) {
        let epoch = self.epoch
        enqueue { [weak self] in
            guard let self, !self.closed, epoch == self.epoch, self.state == .complete else { return }
            let old = self.store
            guard let result = await self.worker.applyLocalizedStems(old, tag: self.keysTag, stems: stems, query: self.query),
                  !self.closed, epoch == self.epoch, self.store.version == old.version else { return }
            self.applyLocalizedPatch(result)
        }
    }
}
