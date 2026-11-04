import Foundation
import Synchronization
import UniformTypeIdentifiers

/// Interned UTType table (§4.2 Types). Index 0/1/2 are fixed; others are added on first sighting.
public final class TypeRegistry: Sendable {
    public static let shared = TypeRegistry()
    public static let folderIndex: UInt16 = 0     // public.folder
    public static let dataIndex: UInt16 = 1       // public.data (no extension)
    public static let symlinkIndex: UInt16 = 2    // public.symlink

    private struct Key: Hashable { var ext: String; var isDirectory: Bool }
    private struct State {
        var byKey: [Key: UInt16] = [:]
        var types: [UTType] = [.folder, .data, .symbolicLink]
        var packages: [Bool] = [false, false, false]
        var applications: [Bool] = [false, false, false]
        /// The system's localizedDescription; nil for dynamic (unregistered) types, which read as the generic text.
        var descriptions: [String?] = []
        var genericDocument = "Document"
        var genericFolder = "Folder"
        var rankCache: (version: Int, ranks: [UInt16])?

        func description(_ index: Int) -> String {
            descriptions[index] ?? (index == Int(TypeRegistry.folderIndex) || packages[index] ? genericFolder : genericDocument)
        }
    }
    private let state: Mutex<State>

    public init() {
        var s = State()
        s.descriptions = s.types.map(Self.systemDescription)
        state = Mutex(s)
    }

    public var version: Int { state.withLock { $0.types.count } }

    /// Interns (lowercased extension, isDirectory). Thread-safe (Mutex). ~O(1) after first sighting.
    /// Directories whose extension isn't a package type map to folderIndex ("v1.2" is a folder).
    public func index(forExtension ext: Substring, isDirectory: Bool) -> UInt16 {
        if ext.isEmpty { return isDirectory ? Self.folderIndex : Self.dataIndex }
        let key = Key(ext: ext.lowercased(), isDirectory: isDirectory)
        if let hit = state.withLock({ $0.byKey[key] }) { return hit }
        // Resolve outside the lock (UTType lookups take ~µs), then insert (another thread may have won).
        let resolved: UTType? = isDirectory
            ? UTType(filenameExtension: key.ext, conformingTo: .directory)
            : UTType(filenameExtension: key.ext, conformingTo: .data)
        return state.withLock { s in
            if let hit = s.byKey[key] { return hit }
            let index: UInt16
            if let type = resolved, !(isDirectory && !type.conforms(to: .package)), s.types.count < Int(UInt16.max) {
                let package = isDirectory && type.conforms(to: .package)
                if let existing = s.types.indices.first(where: { s.types[$0] == type && s.packages[$0] == package }) {
                    index = UInt16(existing)
                } else {
                    index = UInt16(s.types.count)
                    s.types.append(type)
                    s.packages.append(package)
                    s.applications.append(type.conforms(to: .application))
                    s.descriptions.append(Self.systemDescription(type))
                }
            } else {
                index = isDirectory ? Self.folderIndex : Self.dataIndex
            }
            s.byKey[key] = index
            return index
        }
    }

    public func type(at index: UInt16) -> UTType { state.withLock { $0.types[Int(index)] } }
    public func isPackage(_ index: UInt16) -> Bool { state.withLock { $0.packages[Int(index)] } }
    public func isApplication(_ index: UInt16) -> Bool { state.withLock { $0.applications[Int(index)] } }
    public func localizedDescription(_ index: UInt16) -> String { state.withLock { $0.description(Int(index)) } }

    /// The Kind text for types the system can't describe (dynamic types of unregistered extensions): the UI passes
    /// its localized "Document" / "Folder" at launch, before any listing (the defaults are the English text).
    public func setGenericDescriptions(document: String, folder: String) {
        state.withLock { s in
            s.genericDocument = document
            s.genericFolder = folder
            s.rankCache = nil
        }
    }

    private static func systemDescription(_ type: UTType) -> String? {
        type.isDynamic ? nil : type.localizedDescription
    }

    /// Rank by localizedDescription (localizedStandardCompare); recomputed when the table grows.
    /// Equal descriptions share a rank, so the name tie-break decides.
    public func kindRanks() -> (version: Int, ranks: [UInt16]) {
        let (version, cached, descriptions) = state.withLock { s in
            (s.types.count, s.rankCache, s.descriptions.indices.map { s.description($0) })
        }
        if let cached, cached.version == version { return cached }
        let order = descriptions.indices.sorted {
            descriptions[$0].localizedStandardCompare(descriptions[$1]) == .orderedAscending
        }
        var ranks = [UInt16](repeating: 0, count: descriptions.count)
        var rank: UInt16 = 0
        for (position, index) in order.enumerated() {
            if position > 0, descriptions[order[position - 1]].localizedStandardCompare(descriptions[index]) != .orderedSame {
                rank += 1
            }
            ranks[index] = rank
        }
        let result = (version, ranks)
        state.withLock { s in if s.types.count == version { s.rankCache = result } }
        return result
    }
}
