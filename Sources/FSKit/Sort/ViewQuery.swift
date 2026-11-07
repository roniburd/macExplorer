public enum SortField: String, Sendable, Codable, CaseIterable {
    case name, dateModified, size, kind, dateCreated, fileExtension            // Phase 1 (raw values stable)
    case tags, dateLastOpened, permissions, owner, comments, path               // Phase 2
}

extension SortField {
    /// The Phase 1 fields, ordered from `Entry` values alone (in this order).
    public static let entryFields: [SortField] = [.name, .dateModified, .size, .kind, .dateCreated, .fileExtension]
    /// Fields whose values come from extended attributes loaded on demand (P2-15/P2-16).
    public var isExtended: Bool {
        switch self {
        case .tags, .dateLastOpened, .permissions, .owner, .comments: true
        default: false
        }
    }
}

public struct SortDescriptor: Sendable, Codable, Hashable {
    public var field: SortField
    public var ascending: Bool
    public init(field: SortField, ascending: Bool) { self.field = field; self.ascending = ascending }
    public static let `default` = SortDescriptor(field: .name, ascending: true)
}

public struct ViewQuery: Sendable, Hashable {
    public var sort: SortDescriptor
    public var showHidden: Bool
    public var filter: String                             // "" = no filter
    /// Display names keep every extension (Settings "Show all filename extensions"); sort/search keys follow.
    public var showAllExtensions: Bool
    /// Phase 3 search criteria (kind/size/date/extension filters, name globs): nil = none; applied with `filter`.
    public var criteria: SearchCriteria?
    public init(sort: SortDescriptor = .default, showHidden: Bool = false, filter: String = "", showAllExtensions: Bool = false,
                criteria: SearchCriteria? = nil) {
        self.sort = sort
        self.showHidden = showHidden
        self.filter = filter
        self.showAllExtensions = showAllExtensions
        self.criteria = criteria
    }
}
