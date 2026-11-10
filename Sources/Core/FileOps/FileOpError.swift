import Foundation
import Darwin

public enum ErrorResolution: Sendable, Equatable { case retry, skip, skipAll, cancel, unlockAndContinue, continueAnyway }

public enum FileOpErrorKind: Sendable, Equatable {
    case permissionDenied
    case blockedByMacOS
    case locked
    case readOnlyVolume
    case noSpace(needed: Int64?, available: Int64?)
    case inUse
    case nameTooLong
    case sourceGone
    case intoItself
    case changedDuringMove
    case noTrash
    /// An archive entry would be written outside the destination (P4-10); nothing was extracted.
    case unsafeArchive
    /// Not an archive format Extract Here reads (P4-10).
    case unsupportedArchive
    case other(code: Int32, message: String)

    /// `isLockedItem`: the item (or its parent, for creates) has UF_IMMUTABLE; EPERM then means "locked".
    public init(errno code: Int32, isLockedItem: Bool) {
        switch code {
        case EACCES: self = .permissionDenied
        case EPERM: self = isLockedItem ? .locked : .blockedByMacOS
        case EROFS: self = .readOnlyVolume
        case ENOSPC, EDQUOT: self = .noSpace(needed: nil, available: nil)
        case EBUSY, ETXTBSY: self = .inUse
        case ENAMETOOLONG: self = .nameTooLong
        case ENOENT: self = .sourceGone
        default: self = .other(code: code, message: String(cString: strerror(code)))
        }
    }

    /// Maps a Foundation error (FileManager, URL resource APIs) by its POSIX code.
    init(error: any Error, isLockedItem: Bool) {
        if let e = error as? FileOpError { self = e.kind; return }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain { self.init(errno: Int32(ns.code), isLockedItem: isLockedItem); return }
        if let under = ns.userInfo[NSUnderlyingErrorKey] as? NSError, under.domain == NSPOSIXErrorDomain {
            self.init(errno: Int32(under.code), isLockedItem: isLockedItem); return
        }
        switch CocoaError.Code(rawValue: ns.code) {
        case .fileNoSuchFile, .fileReadNoSuchFile: self = .sourceGone
        case .fileWriteNoPermission, .fileReadNoPermission: self = .permissionDenied
        case .fileWriteVolumeReadOnly: self = .readOnlyVolume
        case .fileWriteOutOfSpace: self = .noSpace(needed: nil, available: nil)
        case .featureUnsupported: self = .noTrash
        default: self = .other(code: Int32(ns.code), message: ns.localizedDescription)
        }
    }

    /// §6.5 actions. The UI shows "Open Privacy Settings" for .blockedByMacOS and answers .retry after opening it.
    public var allowedResolutions: [ErrorResolution] {
        switch self {
        case .permissionDenied: [.retry, .skip, .skipAll, .cancel]
        case .blockedByMacOS: [.retry, .skip, .cancel]
        case .locked: [.unlockAndContinue, .skip, .cancel]
        case .readOnlyVolume: [.cancel]
        case .noSpace: [.retry, .cancel]
        case .inUse: [.retry, .skip, .cancel]
        case .nameTooLong, .sourceGone, .intoItself, .noTrash, .unsafeArchive, .unsupportedArchive: [.skip, .cancel]
        case .changedDuringMove, .other: [.retry, .skip, .cancel]
        }
    }
}

public struct FileOpError: Error, Sendable, Equatable {
    public var kind: FileOpErrorKind
    public var url: URL
    public var destination: URL?
    public init(kind: FileOpErrorKind, url: URL, destination: URL? = nil) {
        self.kind = kind; self.url = url; self.destination = destination
    }
}

/// An error that carries an errno; jobs read it through `(error as? any ErrnoCarrying)?.errnoCode ?? EIO`.
protocol ErrnoCarrying { var errnoCode: Int32 { get } }
