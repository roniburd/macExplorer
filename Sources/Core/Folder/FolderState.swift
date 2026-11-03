import Darwin
import MacxFS

/// Why a folder could not be listed (§4.3). UI turns it into an empty state (§5.5).
public enum Reason: Sendable, Equatable {
    case notFound, notADirectory, permissionPOSIX, permissionTCC, volumeGone, other(Int32)

    /// ENOENT→notFound, ENOTDIR→notADirectory, EACCES→permissionPOSIX, EPERM→permissionTCC, ENXIO/ENODEV→volumeGone.
    public init(errno code: Int32) {
        switch code {
        case ENOENT: self = .notFound
        case ENOTDIR: self = .notADirectory
        case EACCES: self = .permissionPOSIX
        case EPERM: self = .permissionTCC
        case ENXIO, ENODEV: self = .volumeGone
        default: self = .other(code)
        }
    }
}

/// `loading → partial → complete | error(Reason) | unresponsive` (§4.3), plus the TCC prompt wait (§4.2).
public enum FolderState: Sendable, Equatable {
    case loading, partial, complete, error(Reason), unresponsive, waitingForPermission

    /// A read failure of the directory itself. An unresponsive volume (stage .unresponsiveVolume, code ETIMEDOUT)
    /// is checked before the errno mapping (S1 Contract note 16).
    init(_ failure: ReadFailure) {
        self = failure.stage == .unresponsiveVolume ? .unresponsive : .error(Reason(errno: failure.code))
    }
}
