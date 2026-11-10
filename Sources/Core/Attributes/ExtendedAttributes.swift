import Foundation
import MacxFS

/// Which extended attributes (§11 Phase 2 columns) a view needs. Read on demand, for the rows asked for only.
public struct ExtendedAttributeSet: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let tags = ExtendedAttributeSet(rawValue: 1 << 0)
    public static let lastOpened = ExtendedAttributeSet(rawValue: 1 << 1)
    public static let permissions = ExtendedAttributeSet(rawValue: 1 << 2)
    public static let owner = ExtendedAttributeSet(rawValue: 1 << 3)
    public static let comments = ExtendedAttributeSet(rawValue: 1 << 4)
    public static let all: ExtendedAttributeSet = [.tags, .lastOpened, .permissions, .owner, .comments]

    /// What sorting by `sortField` needs ([] for the Phase 1 fields and Path).
    public init(sortField: SortField) {
        switch sortField {
        case .tags: self = .tags
        case .dateLastOpened: self = .lastOpened
        case .permissions: self = .permissions
        case .owner: self = .owner
        case .comments: self = .comments
        default: self = []
        }
    }

    /// What showing `column` needs.
    public init(column: ColumnID) { self.init(sortField: column.sortField) }
}

/// One item's extended attributes. Only the fields named by `loaded` are meaningful.
public struct ExtendedAttributes: Sendable, Equatable {
    public var loaded: ExtendedAttributeSet
    /// Finder tag names, in Finder's order (colours are Phase 4).
    public var tags: [String] = []
    public var lastOpened: Date?
    /// `st_mode` of the item itself (never a symlink's target): type and permission bits.
    public var mode: UInt16?
    public var ownerID: UInt32?
    public var ownerName: String?
    public var comment: String?

    public init(loaded: ExtendedAttributeSet = []) { self.loaded = loaded }

    /// `self` with the fields `other` loaded taken from `other`.
    public func merging(_ other: ExtendedAttributes) -> ExtendedAttributes {
        var r = self
        r.loaded.formUnion(other.loaded)
        if other.loaded.contains(.tags) { r.tags = other.tags }
        if other.loaded.contains(.lastOpened) { r.lastOpened = other.lastOpened }
        if other.loaded.contains(.permissions) { r.mode = other.mode }
        if other.loaded.contains(.owner) { r.ownerID = other.ownerID; r.ownerName = other.ownerName }
        if other.loaded.contains(.comments) { r.comment = other.comment }
        return r
    }
}
