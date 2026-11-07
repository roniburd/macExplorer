import Foundation
import MacxFS

public enum RowSourceEvent: Sendable { case changes(ChangeSet), selection(Selection), beginRename(row: Int) }

/// What the Details and Icons views draw: a folder (FolderModel) or search results (SearchResultsModel, P3-06).
@MainActor public protocol RowSource: AnyObject {
    var rowCount: Int { get }
    func entry(atRow row: Int) -> Entry
    /// The real file-system name (operations, rename, paths).
    func name(atRow row: Int) -> String
    /// The name shown in lists (Finder display names, design 2026-11-05 §1).
    func displayName(atRow row: Int) -> String
    func url(atRow row: Int) -> URL
    func parentURL(atRow row: Int) -> URL
    func identity(atRow row: Int) -> RowID
    func row(of id: RowID) -> Int?
    var selection: Selection { get }
    func select(_ command: SelectionCommand)
    var selectedURLs: [URL] { get }
    var selectionSummary: SelectionSummary { get }
    var scrollAnchor: RowID? { get set }
    func isCut(row: Int) -> Bool
    /// FolderModel: `query.sort`; results: their own (SortField.path supported).
    var sortDescriptor: MacxFS.SortDescriptor { get }
    func setSortDescriptor(_ sort: MacxFS.SortDescriptor)
    /// FolderModel false, SearchResultsModel true.
    var showsPathColumn: Bool { get }
    var caseSensitive: Bool { get }
    func validateName(_ proposed: String, renamingRow row: Int?) -> NameValidation
    func observeRows(_ handler: @escaping @MainActor (RowSourceEvent) -> Void) -> ObserverToken
}
