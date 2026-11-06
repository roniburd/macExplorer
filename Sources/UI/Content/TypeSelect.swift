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
    /// Off-main searches that may come back stale (the folder changed under them) before one runs inline.
    static let offMainAttempts = 3
    typealias Search = @Sendable (TypeSelectQuery, EntryStore, Int?, RowMapping?) async -> Int?
    private(set) var buffer = ""
    private var lastKey: ContinuousClock.Instant?
    private let timeout: Duration
    private let now: () -> ContinuousClock.Instant
    /// Runs a large folder's search off main (tests gate it to change the folder mid-search).
    private let search: Search
    private var generation = 0
    private var searchTask: Task<Void, Never>?
    private weak var ownedFolder: FolderModel?
    private var ownedSelection: Set<RowID> = []

    init(timeout: Duration = .seconds(1), now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now },
         search: @escaping Search = TypeSelect.searchOffMain) {
        self.timeout = timeout
        self.now = now
        self.search = search
    }

    nonisolated static func searchOffMain(_ query: TypeSelectQuery, in store: EntryStore, from cursor: Int?,
                                          mapping: RowMapping?) async -> Int? {
        await Task.detached(priority: .userInitiated) { TypeSelectSearch.find(query, in: store, from: cursor, mapping: mapping) }.value
    }

    func reset() {
        buffer = ""
        lastKey = nil
        ownedFolder = nil
        ownedSelection = []
    }

    /// The buffer is non-empty and the last keystroke is within the timeout: a Space now continues the name being
    /// typed instead of toggling Quick Look (P2-11, Review Focus 1).
    var isCollecting: Bool {
        guard !buffer.isEmpty, let lastKey else { return false }
        return now() - lastKey <= timeout
    }

    /// `isCollecting` for `folder`, and its selection is still the one type-select left (QA round 2): a click, ⌘A, a
    /// menu command or any other selection change ends the name being typed, so the next Space is Quick Look's.
    func isCollecting(in folder: FolderModel?) -> Bool {
        guard isCollecting, let folder else { return false }
        return ownsSelection(of: folder)
    }

    private func ownsSelection(of folder: FolderModel) -> Bool {
        folder === ownedFolder && folder.selection.ids == ownedSelection
    }

    /// Type-select's view of the selection: what it was at the last keystroke, or what the last match set.
    private func takeSelection(of folder: FolderModel) {
        ownedFolder = folder
        ownedSelection = folder.selection.ids
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

    /// `collecting`: `isCollecting`. Spaces are accepted only while collecting; a leading space never starts a buffer.
    static func accepts(_ event: NSEvent, collecting: Bool) -> Bool {
        guard event.specialKey == nil, event.modifierFlags.intersection([.command, .control]).isEmpty,
              let characters = event.characters, !characters.isEmpty else { return false }
        if characters.allSatisfy({ $0 == " " }) { return collecting }
        return characters.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    func handle(_ characters: String, folder: FolderModel, list: FileListView, mapping: RowMapping? = nil) {
        if !buffer.isEmpty, !ownsSelection(of: folder) { reset() }   // the selection moved since: a new name
        takeSelection(of: folder)
        let query = append(characters)
        generation += 1
        run(query, token: generation, folder: folder, list: list, mapping: mapping, attempt: 1)
    }

    /// A newer key press (`token`) supersedes a search. A store that changed while the search ran (a watcher patch,
    /// a re-sort) makes its row stale but not the key press: the query runs again on the current rows, so the
    /// keystroke is never dropped. After `offMainAttempts` stale results (a folder that keeps changing) it runs inline.
    /// `mapping` (grouped Details, P2-10) is the one captured at the key press.
    private func run(_ query: TypeSelectQuery, token: Int, folder: FolderModel, list: FileListView, mapping: RowMapping?,
                     attempt: Int) {
        let store = folder.store
        let cursor = folder.selection.cursor.flatMap { folder.row(of: $0) }
        searchTask?.cancel()
        searchTask = nil
        if store.visibleCount <= Self.inlineLimit || attempt > Self.offMainAttempts {
            apply(TypeSelectSearch.find(query, in: store, from: cursor, mapping: mapping), folder: folder, list: list)
            return
        }
        let version = store.version, search = self.search
        searchTask = Task { [weak self, weak folder, weak list] in
            let row = await search(query, store, cursor, mapping)
            guard let self, let folder, let list, token == self.generation else { return }
            guard folder.store.version == version else {
                self.run(query, token: token, folder: folder, list: list, mapping: mapping, attempt: attempt + 1)
                return
            }
            self.apply(row, folder: folder, list: list)
        }
    }

    /// A selection the user changed while an off-main search ran (a click) is kept: the late match is dropped.
    private func apply(_ row: Int?, folder: FolderModel, list: FileListView) {
        guard let row, ownsSelection(of: folder) else { return }
        folder.select(.set(IndexSet(integer: row), cursor: row))
        takeSelection(of: folder)
        list.scrollToRow(row)
    }
}
