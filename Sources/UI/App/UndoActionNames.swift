import Core

/// Localized undo action names ("Undo Copy"), installed as `CoreEnvironment.undoActionName` at launch (S3 note 7).
public enum UndoActionNames {
    public static func name(for description: JobDescription) -> String {
        switch description.verb {
        case .copying: L10n.string("Copy")
        case .moving: L10n.string("Move")
        case .trashing: L10n.string("Move to Trash")
        case .deleting: L10n.string("Delete")
        case .duplicating: L10n.string("Duplicate")
        case .creating: L10n.string("New Item")
        case .renaming: L10n.string("Rename")
        case .makingAlias: L10n.string("Make Alias")
        case .makingSymlink: L10n.string("Make Symbolic Link")
        case .changingPermissions: L10n.string("Change Permissions")
        case .changingAttributes: L10n.string("Change Attributes")
        case .changingAccess: L10n.string("Change Access")
        case .changingIcon: L10n.string("Change Icon")
        case .compressing: L10n.string("Compress")
        case .extracting: L10n.string("Extract")
        case .undoing: L10n.string("Undo")
        case .redoing: L10n.string("Redo")
        }
    }
}
