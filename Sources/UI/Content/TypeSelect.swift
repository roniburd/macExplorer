// Sources/UI/Content/TypeSelect.swift
import AppKit
import Core
import MacxFS

struct TypeSelectQuery: Equatable, Sendable {
    var text: String
    var cycle: Bool   // one repeated character: move to the next match after the cursor (Explorer)
}

/// Prefix search on display rows, folded like the filter (§4.2 SortKeys rule 5). O(rows) with a bounded fold per
/// name, so big folders run it off main.
enum TypeSelectSearch {
    /// `mapping` (grouped Details, P2-10): rows of collapsed groups are skipped.
    static func find(_ query: TypeSelectQuery, in store: EntryStore, from cursorRow: Int?, mapping: RowMapping? = nil) -> Int? {
        let needle = SortKeys.searchFold(query.text)
        let count = store.visibleCount
        guard !needle.isEmpty, count > 0 else { return nil }
        let begin = cursorRow.map { query.cycle ? $0 + 1 : $0 } ?? 0
        let prefixLength = query.text.count + 4
        for step in 0..<count {
            let row = (begin + step) % count
            if let mapping, mapping.tableRow(forModelRow: row) == nil { continue }
            let name = store.name(store.storageIndex(forRow: row))
            if SortKeys.searchFold(String(name.prefix(prefixLength))).starts(with: needle) { return row }
        }
        return nil
    }
}

@MainActor
final class TypeSelect {
    static let inlineLimit = 2_000
    private(set) var buffer = ""
    private var lastKey: ContinuousClock.Instant?
    private let timeout: Duration
    private let now: () -> ContinuousClock.Instant
    private var generation = 0
    private var searchTask: Task<Void, Never>?

    init(timeout: Duration = .seconds(1), now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.timeout = timeout
        self.now = now
    }

    func reset() {
        buffer = ""
        lastKey = nil
    }

    func append(_ characters: String) -> TypeSelectQuery {
        let time = now()
        if let lastKey, time - lastKey > timeout { buffer = "" }
        lastKey = time
        buffer += characters
        let first = buffer.first.map(String.init) ?? ""
        let repeated = buffer.allSatisfy { String($0) == first }
        return TypeSelectQuery(text: repeated ? first : buffer, cycle: repeated)
    }

    static func accepts(_ event: NSEvent, bufferEmpty: Bool) -> Bool {
        guard event.specialKey == nil, event.modifierFlags.intersection([.command, .control]).isEmpty,
              let characters = event.characters, !characters.isEmpty else { return false }
        if characters == " " { return !bufferEmpty }
        return characters.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    func handle(_ characters: String, folder: FolderModel, list: FileListView, mapping: RowMapping? = nil) {
        let query = append(characters)
        let store = folder.store
        let cursor = folder.selection.cursor.flatMap { folder.row(of: $0) }
        generation += 1
        let token = generation
        let version = store.version
        if store.visibleCount <= Self.inlineLimit {
            apply(TypeSelectSearch.find(query, in: store, from: cursor, mapping: mapping), token: token, version: version, folder: folder, list: list)
            return
        }
        searchTask?.cancel()
        searchTask = Task { [weak self, weak folder, weak list] in
            let row = await Task.detached(priority: .userInitiated) {
                TypeSelectSearch.find(query, in: store, from: cursor, mapping: mapping)
            }.value
            guard let self, let folder, let list else { return }
            self.apply(row, token: token, version: version, folder: folder, list: list)
        }
    }

    private func apply(_ row: Int?, token: Int, version: UInt64, folder: FolderModel, list: FileListView) {
        guard let row, token == generation, folder.store.version == version else { return }
        folder.select(.set(IndexSet(integer: row), cursor: row))
        list.scrollToRow(row)
    }
}
