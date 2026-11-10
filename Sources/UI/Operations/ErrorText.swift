import Foundation
import Core

/// User-facing text for typed Core problems. Core never produces English (overview Global Constraints).
@MainActor
enum ErrorText {
    static func renameProblem(_ problem: NameProblem, name: String) -> String {
        switch problem {
        case .empty: L10n.string("A name can't be empty.")
        case .reserved: String(format: L10n.string("'%@' is not a valid name."), name)
        case .containsSlash: L10n.string("A name can't contain '/'.")
        case .tooLong: L10n.string("The name is too long.")
        case .duplicate: String(format: L10n.string("The name '%@' is already taken."), name)
        }
    }
}

extension ErrorText {
    /// §6.5 "Message (plain)" for one item of a job. Used inline by Properties (P1-37) and as the error dialog's title
    /// (P1-38). `verb` picks the wording of permission errors.
    static func jobError(_ kind: FileOpErrorKind, name: String, verb: JobVerb? = nil) -> String {
        switch kind {
        case .permissionDenied: String(format: L10n.string(permissionKey(verb)), name)
        case .blockedByMacOS: String(format: L10n.string("macOS is blocking access to '%@'."), name)
        case .locked: String(format: L10n.string("'%@' is locked."), name)
        case .readOnlyVolume: L10n.string("The destination is read-only.")
        case .noSpace(let needed?, let available?):
            String(format: L10n.string("Not enough space (needs %@, %@ available)."), Formatters.bytes(needed), Formatters.bytes(available))
        case .noSpace: L10n.string("Not enough space on the destination.")
        case .inUse: String(format: L10n.string("'%@' is in use by another app."), name)
        case .nameTooLong: String(format: L10n.string("The name '%@' is too long for the destination."), name)
        case .sourceGone: String(format: L10n.string("'%@' no longer exists."), name)
        case .intoItself: String(format: L10n.string("'%@' can't be moved or copied into itself."), name)
        case .changedDuringMove: String(format: L10n.string("'%@' changed while it was being moved, so it was left in place."), name)
        case .noTrash: String(format: L10n.string("'%@' can't be moved to the Trash."), name)
        case .unsafeArchive:
            String(format: L10n.string("“%@” can't be extracted safely because it contains items that would be written outside the destination folder."), name)
        case .unsupportedArchive: String(format: L10n.string("“%@” isn't an archive macExplorer can open."), name)
        case .other(let code, let message):
            String(format: L10n.string("An error occurred with '%@': %@ (error %lld)."), name, message, Int64(code))
        }
    }

    private static func permissionKey(_ verb: JobVerb?) -> String {
        switch verb {
        case .copying?: "You don't have permission to copy '%@'."
        case .moving?: "You don't have permission to move '%@'."
        case .trashing?: "You don't have permission to move '%@' to the Trash."
        case .deleting?: "You don't have permission to delete '%@'."
        case .duplicating?: "You don't have permission to duplicate '%@'."
        case .creating?: "You don't have permission to create '%@'."
        case .renaming?, .batchRenaming?: "You don't have permission to rename '%@'."
        case .makingAlias?, .makingSymlink?: "You don't have permission to make a link to '%@'."
        case .compressing?: "You don't have permission to compress '%@'."
        case .extracting?: "You don't have permission to extract '%@'."
        case .changingAccess?: "You don't have permission to change the access of '%@'."
        case .changingPermissions?, .changingAttributes?, .changingIcon?, .undoing?, .redoing?, nil: "You don't have permission to change '%@'."
        }
    }
}
