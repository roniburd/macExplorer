import Foundation
import MacxFS

/// Per-folder view settings (design 2026-11-05 §2, extended with the Phase 2 fields): what one level of the
/// resolution chain sets. Every field is optional: nil = not set at this level. A folder's own record in
/// `FolderViewStore` holds only the fields the user changed there.
public struct FolderViewSettings: Codable, Equatable, Sendable {
    public var viewMode: ViewMode?
    public var iconSize: IconSize?
    public var density: Density?
    public var sort: MacxFS.SortDescriptor?
    public var columns: [ColumnSetting]?
    public var groupBy: GroupBy?
    public var calculateFolderSizes: Bool?

    public init(viewMode: ViewMode? = nil, iconSize: IconSize? = nil, density: Density? = nil,
                sort: MacxFS.SortDescriptor? = nil, columns: [ColumnSetting]? = nil, groupBy: GroupBy? = nil,
                calculateFolderSizes: Bool? = nil) {
        self.viewMode = viewMode
        self.iconSize = iconSize
        self.density = density
        self.sort = sort
        self.columns = columns
        self.groupBy = groupBy
        self.calculateFolderSizes = calculateFolderSizes
    }

    public var isEmpty: Bool { self == FolderViewSettings() }

    /// Fields set here win; the rest come from `fallback`.
    public func over(_ fallback: FolderViewSettings) -> FolderViewSettings {
        FolderViewSettings(viewMode: viewMode ?? fallback.viewMode, iconSize: iconSize ?? fallback.iconSize,
                           density: density ?? fallback.density, sort: sort ?? fallback.sort,
                           columns: columns ?? fallback.columns, groupBy: groupBy ?? fallback.groupBy,
                           calculateFolderSizes: calculateFolderSizes ?? fallback.calculateFolderSizes)
    }

    /// Every field resolved: set here, else from `defaults`.
    public func resolved(over defaults: FolderViewState) -> FolderViewState {
        FolderViewState(mode: viewMode ?? defaults.mode, columns: columns ?? defaults.columns, sort: sort ?? defaults.sort,
                        iconSize: iconSize ?? defaults.iconSize, density: density ?? defaults.density,
                        groupBy: groupBy ?? defaults.groupBy,
                        calculateFolderSizes: calculateFolderSizes ?? defaults.calculateFolderSizes)
    }
}

public enum FolderViewResolver {
    /// Folders whose built-in default is Large Icons (Finder's own Applications folders open as icons).
    public static func builtIn(for directory: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> FolderViewSettings {
        let path = FolderViewLocator.standardPath(directory)
        let homeApps = FolderViewLocator.standardPath(home.appending(path: "Applications", directoryHint: .isDirectory))
        let apps = ["/Applications", "/System/Applications", homeApps]
        guard apps.contains(path) || apps.contains(where: { path == $0 + "/Utilities" }) else { return FolderViewSettings() }
        return FolderViewSettings(viewMode: .icons, iconSize: .large)
    }

    /// Field by field: MacExplorer's entry, then Finder's `.DS_Store`, then the built-in rule, then the global defaults.
    public static func resolve(stored: FolderViewSettings?, finder: FolderViewSettings?, builtIn: FolderViewSettings,
                               defaults: FolderViewState) -> FolderViewState {
        (stored ?? FolderViewSettings()).over((finder ?? FolderViewSettings()).over(builtIn)).resolved(over: defaults)
    }
}

/// Finder's view of a folder from `.DS_Store` (design 2026-11-05 §3). Read-only; never creates or writes files.
public enum FinderFolderView {
    /// The folder's own record ("." in folder/.DS_Store), else its record in the parent's `.DS_Store`. A `.DS_Store`
    /// last modified at or before `writtenAfter` is skipped ("Apply to All Folders" overrides it).
    /// Blocking file reads: call off main.
    public static func read(folder: URL, globalColumns: [ColumnSetting], writtenAfter: Date? = nil) -> FolderViewSettings? {
        let own = records(in: folder, writtenAfter: writtenAfter)?["."]
        let parent = folder.path(percentEncoded: false) == "/" ? nil
            : records(in: folder.deletingLastPathComponent(), writtenAfter: writtenAfter)?[folder.lastPathComponent]
        let mapped = [own, parent].compactMap { $0.map { map($0, globalColumns: globalColumns) } }.filter { !$0.isEmpty }
        return mapped.first
    }

    static func records(in directory: URL, writtenAfter: Date? = nil) -> [String: [String: DSValue]]? {
        let url = directory.appending(path: ".DS_Store", directoryHint: .notDirectory)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        if let writtenAfter {
            var info = stat()
            guard fstat(handle.fileDescriptor, &info) == 0 else { return nil }
            let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                                + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
            guard modified > writtenAfter else { return nil }
        }
        guard let data = try? handle.read(upToCount: DSStore.maxFileSize + 1), data.count <= DSStore.maxFileSize else { return nil }
        return DSStore.parse(data)
    }

    /// Finder's codes → our settings. Unknown or unmapped values are left unset.
    public static func map(_ record: [String: DSValue], globalColumns: [ColumnSetting]) -> FolderViewSettings {
        var out = FolderViewSettings()
        if case .type(let style)? = record["vstl"] {
            switch style {
            case "icnv": out.viewMode = .icons
            case "Nlsv": out.viewMode = .details
            case "clmv": out.viewMode = .columns
            default: break
            }
        }
        if case .blob(let data)? = record["icvp"], let icons = plist(data), let size = number(icons["iconSize"]) {
            out.iconSize = size <= 48 ? .small : size <= 96 ? .medium : .large
        }
        let list = [record["lsvp"], record["lsvP"]].compactMap { value -> [String: Any]? in
            if case .blob(let data)? = value { return plist(data) }
            return nil
        }.first
        if let list {
            let columns = finderColumns(list["columns"])
            if let sortColumn = list["sortColumn"] as? String, let field = sortField(sortColumn) {
                let ascending = (columns[sortColumn]?["ascending"] as? Bool) ?? true
                out.sort = MacxFS.SortDescriptor(field: field, ascending: ascending)
            }
            if !columns.isEmpty { out.columns = mapColumns(columns, globalColumns: globalColumns) }
        }
        return out
    }

    /// Finder's list-view column names for our columns ("label" is Finder's Tags column).
    static let columnIDs: [String: ColumnID] = ["name": .name, "dateModified": .dateModified, "dateCreated": .dateCreated,
                                                "size": .size, "kind": .kind, "label": .tags,
                                                "dateLastOpened": .dateLastOpened, "comments": .comments]

    static func sortField(_ finderColumn: String) -> SortField? { columnIDs[finderColumn]?.sortField }

    /// Column name → attributes, from the dictionary form or the legacy array form (`identifier` key).
    static func finderColumns(_ value: Any?) -> [String: [String: Any]] {
        if let dict = value as? [String: [String: Any]] { return dict }
        if let array = value as? [[String: Any]] {
            var out: [String: [String: Any]] = [:]
            for column in array { if let id = column["identifier"] as? String { out[id] = column } }
            return out
        }
        return [:]
    }

    /// Visibility and width of the columns Finder knows; order by Finder's `index`; "name" stays visible; the
    /// columns Finder has none of (Extension, Permissions, Owner, Path) keep their global setting and relative place.
    static func mapColumns(_ finder: [String: [String: Any]], globalColumns: [ColumnSetting]) -> [ColumnSetting]? {
        var byID: [ColumnID: (visible: Bool?, width: Double?, index: Int?)] = [:]
        for (name, attributes) in finder {
            guard let id = columnIDs[name] else { continue }
            byID[id] = (attributes["visible"] as? Bool, number(attributes["width"]), (attributes["index"] as? NSNumber)?.intValue)
        }
        guard !byID.isEmpty else { return nil }
        var columns = globalColumns.map { column -> ColumnSetting in
            guard let finder = byID[column.id] else { return column }
            var c = column
            if let visible = finder.visible { c.visible = column.id == .name ? true : visible }
            if let width = finder.width, width >= 40, width <= 2_000 { c.width = width }
            return c
        }
        // Stable reorder of the Finder-indexed columns among the slots they occupy.
        let slots = columns.indices.filter { byID[columns[$0].id]?.index != nil }
        let reordered = slots.map { columns[$0] }.enumerated()
            .sorted { (byID[$0.element.id]?.index ?? 0, $0.offset) < (byID[$1.element.id]?.index ?? 0, $1.offset) }
            .map(\.element)
        for (slot, column) in zip(slots, reordered) { columns[slot] = column }
        return columns
    }

    static func plist(_ data: Data) -> [String: Any]? {
        (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }
}
