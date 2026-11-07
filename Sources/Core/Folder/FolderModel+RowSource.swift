import Foundation
import MacxFS

extension FolderModel: RowSource {
    public func parentURL(atRow row: Int) -> URL { directory }
    public var sortDescriptor: MacxFS.SortDescriptor { query.sort }
    public func setSortDescriptor(_ sort: MacxFS.SortDescriptor) {
        var q = query
        q.sort = sort
        setQuery(q)
    }
    public var showsPathColumn: Bool { false }
    public func observeRows(_ handler: @escaping @MainActor (RowSourceEvent) -> Void) -> ObserverToken {
        observe { event in
            switch event {
            case .changes(let c): handler(.changes(c))
            case .selection(let s): handler(.selection(s))
            case .beginRename(let row): handler(.beginRename(row: row))
            default: break     // state, relocate, query, Phase 2 groups/sizes/attributes stay FolderModel-specific
            }
        }
    }
}
