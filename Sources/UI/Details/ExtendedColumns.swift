import AppKit
import Core
import MacxFS

/// One Details column: header title, first-appearance width, text alignment, and the extended attributes its cells
/// need (empty for the Phase 1 columns and Path).
struct ColumnDefinition: Equatable {
    let id: ColumnID
    let title: String
    let defaultWidth: Double
    let alignment: NSTextAlignment
    let required: ExtendedAttributeSet
}

/// The Phase 2 Details columns (§11): Tags, Date Last Opened, Permissions, Owner, Path (search results only) and
/// Comments. Cell text comes from `FolderModel.extendedAttributes(atRow:)` only: a row whose attributes are not
/// loaded yet shows an empty cell, and configuring a cell never does I/O.
@MainActor
enum ExtendedColumns {
    static func definition(_ id: ColumnID) -> ColumnDefinition {
        ColumnDefinition(id: id, title: DetailsColumns.title(id), defaultWidth: id.defaultWidth,
                         alignment: id == .size ? .right : .left, required: ExtendedAttributeSet(column: id))
    }

    /// The union of the visible columns' required attributes (what the controller asks the model to read).
    static func required(visible columns: [ColumnSetting]) -> ExtendedAttributeSet {
        columns.reduce(into: ExtendedAttributeSet()) { set, column in
            if column.visible { set.formUnion(ExtendedAttributeSet(column: column.id)) }
        }
    }

    /// Whether `id`'s cells are filled from extended attributes or the path (refreshed on `.extendedAttributes`).
    static func isExtended(_ id: ColumnID) -> Bool { id.sortField.isExtended }

    /// The text of an extended or Path cell. "" for Phase 1 columns (DetailsViewController formats those), and for
    /// rows whose attributes are not loaded yet.
    static func text(_ id: ColumnID, row: Int, in folder: FolderModel, dateStyle: DateStyle,
                     home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        guard row >= 0, row < folder.rowCount else { return "" }
        if id == .path {
            let parent = folder.url(atRow: row).deletingLastPathComponent()
            return PathFormatter.one(PathItem(url: parent, isDirectory: true), style: .tilde, home: home)
        }
        let wanted = ExtendedAttributeSet(column: id)
        guard !wanted.isEmpty, let attributes = folder.extendedAttributes(atRow: row),
              attributes.loaded.isSuperset(of: wanted) else { return "" }
        switch id {
        case .tags:
            return attributes.tags.joined(separator: ", ")
        case .dateLastOpened:
            return attributes.lastOpened.map { Formatters.date($0, style: dateStyle) } ?? Formatters.folderSize
        case .permissions:
            return attributes.mode.map { PermissionsFormatter.string(mode: $0, kind: folder.entry(atRow: row).kind) } ?? ""
        case .owner:
            return attributes.ownerName ?? attributes.ownerID.map(String.init) ?? ""
        case .comments:
            return singleLine(attributes.comment ?? "")
        case .name, .dateModified, .size, .kind, .dateCreated, .fileExtension, .path:
            return ""
        }
    }

    /// Newlines (any convention) shown as spaces.
    static func singleLine(_ text: String) -> String {
        guard text.contains(where: \.isNewline) else { return text }
        return text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).joined(separator: " ")   // "\r\n" is one Character
    }
}
