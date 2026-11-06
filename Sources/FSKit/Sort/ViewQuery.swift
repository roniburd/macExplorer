public enum SortField: String, Sendable, Codable, CaseIterable { case name, dateModified, size, kind, dateCreated, fileExtension }

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
    public init(sort: SortDescriptor = .default, showHidden: Bool = false, filter: String = "", showAllExtensions: Bool = false) {
        self.sort = sort
        self.showHidden = showHidden
        self.filter = filter
        self.showAllExtensions = showAllExtensions
    }
}
