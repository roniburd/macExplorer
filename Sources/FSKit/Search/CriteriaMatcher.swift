import Foundation
import UniformTypeIdentifiers

/// Pure, allocation-free per entry after the first sighting of each (typeIndex, kind). Not shared across
/// threads: each permutation chunk / crawler read creates its own (a value type with a small kind cache).
public struct CriteriaMatcher: Sendable {
    private let criteria: SearchCriteria
    private let patterns: [NamePattern]
    private let extensions: [[UInt8]]?
    /// Each group is "any of these kinds"; every group must match (`kinds`, then `andKinds`). nil = no kind filter.
    private let kindGroups: [[(KindFilter, [UTType])]]?
    private let types: TypeRegistry
    private var kindCache: [UInt32: Bool] = [:]
    /// A name term has "?": pass the unfolded names to `matches` (folding can expand one character, ß → "ss").
    public let needsNames: Bool

    public init(_ criteria: SearchCriteria, types: TypeRegistry) {
        self.criteria = criteria
        self.types = types
        self.patterns = criteria.nameTerms.map { NamePattern($0.text) }
        self.extensions = criteria.extensions.map { set in set.sorted().map { SortKeys.searchFold($0) } }
        let groups = [criteria.kinds, criteria.andKinds].compactMap { $0 }
            .map { set in set.sorted { $0.rawValue < $1.rawValue }.map { ($0, $0.utTypes) } }
        self.kindGroups = groups.isEmpty ? nil : groups
        self.needsNames = patterns.contains(where: \.needsOriginal)
    }

    /// `foldedName`: searchFold of the name the user sees (display name). `foldedFileName`: searchFold of the
    /// on-disk name when it can differ (Finder hides ".app" and per-file "hide extension" extensions, or shows a
    /// localized name); name terms match either, and the extension filter always uses the on-disk name.
    /// `name` / `fileName`: the same names unfolded, used (when `needsNames`) so "?" matches one character of them.
    public mutating func matches(_ entry: Entry, foldedName: UnsafeRawBufferPointer,
                                 foldedFileName: UnsafeRawBufferPointer? = nil, name: String? = nil, fileName: String? = nil) -> Bool {
        for pattern in patterns where !pattern.matches(foldedName, original: name) {
            guard let foldedFileName, pattern.matches(foldedFileName, original: fileName) else { return false }
        }
        if let range = criteria.size {
            if entry.kind == .directory || entry.kind == .package { return false }
            if !range.contains(entry.size) { return false }
        }
        if let range = criteria.modified, !range.contains(entry.mtime) { return false }
        if let range = criteria.created, !range.contains(entry.ctime) { return false }
        if let extensions {
            // Folders have no extension ("v1.2" is a folder, SortKeys.extensionKey); packages keep theirs.
            guard entry.kind != .directory, let ext = Self.foldedExtension(foldedFileName ?? foldedName),
                  extensions.contains(where: { $0.elementsEqual(ext) }) else { return false }
        }
        if let kindGroups, !kindMatches(entry, kindGroups) { return false }
        return true
    }

    private mutating func kindMatches(_ entry: Entry, _ groups: [[(KindFilter, [UTType])]]) -> Bool {
        let key = UInt32(entry.typeIndex) << 8 | UInt32(entry.kind.rawValue)
        if let hit = kindCache[key] { return hit }
        let type = types.type(at: entry.typeIndex)
        let result = groups.allSatisfy { kinds in
            kinds.contains { filter, roots in
                switch filter {
                case .folder: return entry.kind == .directory
                default: return entry.kind != .directory && roots.contains { type.conforms(to: $0) }
                }
            }
        }
        kindCache[key] = result
        return result
    }

    /// Bytes after the last "." of a folded name; nil when there is none, it is the first byte, or it is last.
    static func foldedExtension(_ folded: UnsafeRawBufferPointer) -> UnsafeRawBufferPointer? {
        guard let dot = folded.lastIndex(of: UInt8(ascii: ".")), dot > 0, dot < folded.count - 1 else { return nil }
        return UnsafeRawBufferPointer(rebasing: folded[(dot + 1)...])
    }
}
