import Foundation
import Darwin
import MacxFS

public struct FileIdentity: Sendable, Codable, Hashable {
    public var device: UInt64
    public var inode: UInt64
    public init(device: UInt64, inode: UInt64) { self.device = device; self.inode = inode }
    /// lstat; lane only.
    public static func of(path: String) -> FileIdentity? {
        assertOffMain()
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return FileIdentity(device: UInt64(UInt32(bitPattern: st.st_dev)), inode: st.st_ino)
    }
}

public struct AttributeSnapshot: Sendable, Codable, Equatable {
    public var locked: Bool?
    public var hidden: Bool?
    public var extensionHidden: Bool?
    public var mode: UInt16?
    public var quarantine: Data?
    public init(locked: Bool? = nil, hidden: Bool? = nil, extensionHidden: Bool? = nil, mode: UInt16? = nil, quarantine: Data? = nil) {
        self.locked = locked; self.hidden = hidden; self.extensionHidden = extensionHidden; self.mode = mode; self.quarantine = quarantine
    }
}

public enum ItemAction: Sendable, Codable, Equatable {
    case created(URL, FileIdentity)
    case createdDirectory(URL, FileIdentity)
    case moved(from: URL, to: URL, FileIdentity)
    case renamed(from: URL, to: URL, FileIdentity)
    case trashed(original: URL, trashURL: URL, FileIdentity)
    case replaced(original: URL, trashURL: URL, FileIdentity)
    case modeChanged(URL, old: UInt16, new: UInt16)
    case attributesChanged(URL, old: AttributeSnapshot, new: AttributeSnapshot)
    case tagsChanged(URL, old: [FileTag], new: [FileTag])
    /// nil = no custom icon. In-memory only (undo stack), like every JobRecord; the journal never holds it.
    case customIconChanged(URL, previous: IconImageData?, new: IconImageData?)
    case deleted(URL)

    var urls: [URL] {
        switch self {
        case .created(let u, _), .createdDirectory(let u, _), .modeChanged(let u, _, _), .attributesChanged(let u, _, _), .tagsChanged(let u, _, _),
             .customIconChanged(let u, _, _), .deleted(let u): [u]
        case .moved(let a, let b, _), .renamed(let a, let b, _): [a, b]
        case .trashed(let a, let b, _), .replaced(let a, let b, _): [a, b]
        }
    }
}

public struct JobRecord: Sendable, Codable, Equatable {
    public var id: JobID
    public var verb: JobVerb
    public var actions: [ItemAction]
    public init(id: JobID, verb: JobVerb, actions: [ItemAction]) { self.id = id; self.verb = verb; self.actions = actions }
    public var isUndoable: Bool {
        !actions.isEmpty && !actions.contains { if case .deleted = $0 { true } else { false } }
    }
}

public struct SkippedItem: Sendable, Equatable {
    public var url: URL
    public var reason: FileOpErrorKind?            // nil = conflict skipped
    public init(url: URL, reason: FileOpErrorKind?) { self.url = url; self.reason = reason }
}

public struct JobOutcome: Sendable, Equatable {
    public var record: JobRecord
    public var skipped: [SkippedItem]
    public var wasCancelled: Bool
    public var created: [URL]
    public var localChanges: [LocalChange]
    public init(record: JobRecord, skipped: [SkippedItem], wasCancelled: Bool, created: [URL], localChanges: [LocalChange]) {
        self.record = record; self.skipped = skipped; self.wasCancelled = wasCancelled; self.created = created; self.localChanges = localChanges
    }
}
