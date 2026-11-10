import Foundation

public struct JobID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let raw: UUID
    public init() { raw = UUID() }
    public var description: String { raw.uuidString.lowercased() }
    /// First 8 hex chars; used in partial and temporary names.
    public var short: String { String(description.prefix(8)) }
}

public struct OriginID: Hashable, Sendable, Codable {
    public let raw: Int
    public init(raw: Int) { self.raw = raw }
}

/// "New Folder", "Untitled.txt", "Untitled".
public enum NewItemKind: String, Sendable, Codable { case folder, textFile, emptyFile }

public struct ModeChange: Sendable, Codable, Equatable {
    public var mode: UInt16
    public var applyToDirectories: Bool
    public var applyToFiles: Bool
    /// Files take only the r/w bits of `mode` and keep their own execute bits (Properties' "Apply to enclosed
    /// items…": documents must not turn executable). Directories always take all rwx bits.
    public var keepsFileExecuteBits: Bool
    public init(mode: UInt16, applyToDirectories: Bool = true, applyToFiles: Bool = true, keepsFileExecuteBits: Bool = false) {
        self.mode = mode; self.applyToDirectories = applyToDirectories; self.applyToFiles = applyToFiles
        self.keepsFileExecuteBits = keepsFileExecuteBits
    }

    private enum CodingKeys: String, CodingKey { case mode, applyToDirectories, applyToFiles, keepsFileExecuteBits }

    /// Journal records written before `keepsFileExecuteBits` existed decode with it false.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(mode: try c.decode(UInt16.self, forKey: .mode),
                  applyToDirectories: try c.decode(Bool.self, forKey: .applyToDirectories),
                  applyToFiles: try c.decode(Bool.self, forKey: .applyToFiles),
                  keepsFileExecuteBits: try c.decodeIfPresent(Bool.self, forKey: .keepsFileExecuteBits) ?? false)
    }

    /// The mode bits (0o777) an item of `mode` gets.
    public func applied(to mode: UInt16, isDirectory: Bool) -> UInt16 {
        let bits: UInt16 = isDirectory || !keepsFileExecuteBits ? 0o777 : 0o666
        return (mode & ~bits) | (self.mode & bits)
    }
}

public enum AttributeEdit: Sendable, Codable, Equatable {
    case locked(Bool), hidden(Bool), extensionHidden(Bool), permissions(UInt16), removeQuarantine
}

public indirect enum JobKind: Sendable, Equatable {
    case copy(sources: [URL], destination: URL)
    case move(sources: [URL], destination: URL)
    case trash([URL])
    case delete([URL])
    case duplicate([URL])
    case newItem(NewItemKind, in: URL)
    case rename(URL, to: String)
    case alias(sources: [URL], destination: URL)
    case symlink(sources: [URL], destination: URL)
    case chmodRecursive(URL, ModeChange)
    case setAttributes([URL], AttributeEdit)
    /// nil removes the custom icon (P4-07).
    case setCustomIcon([URL], IconImageData?)
    /// A zip or Apple Archive of the items, next to the first one (P4-09).
    case compress([URL], ArchiveFormat)
    /// Extract Here: the archive's contents next to it (P4-10).
    case extract(URL)
    case undo(JobRecord)
    case redo(JobRecord)
}

extension JobKind {
    /// Every path the job may read or write (scheduling, sandbox guard in tests).
    var allURLs: [URL] {
        switch self {
        case .copy(let s, let d), .move(let s, let d), .alias(let s, let d), .symlink(let s, let d): return s + [d]
        case .trash(let u), .delete(let u), .duplicate(let u), .setAttributes(let u, _), .setCustomIcon(let u, _),
             .compress(let u, _): return u
        case .newItem(_, let d): return [d]
        case .rename(let u, _), .chmodRecursive(let u, _), .extract(let u): return [u]
        case .undo(let r), .redo(let r): return r.actions.flatMap(\.urls)
        }
    }
    var verb: JobVerb {
        switch self {
        case .copy: .copying
        case .move: .moving
        case .trash: .trashing
        case .delete: .deleting
        case .duplicate: .duplicating
        case .newItem: .creating
        case .rename: .renaming
        case .alias: .makingAlias
        case .symlink: .makingSymlink
        case .chmodRecursive: .changingPermissions
        case .setAttributes: .changingAttributes
        case .setCustomIcon: .changingIcon
        case .compress: .compressing
        case .extract: .extracting
        case .undo: .undoing
        case .redo: .redoing
        }
    }
    var jobDescription: JobDescription {
        func folderName(_ u: URL?) -> String? { u.map { $0.deletingLastPathComponent().lastPathComponent } }
        switch self {
        case .copy(let s, let d), .move(let s, let d), .alias(let s, let d), .symlink(let s, let d):
            return JobDescription(verb: verb, itemCount: s.count, firstItemName: s.first?.lastPathComponent,
                                  sourceFolderName: folderName(s.first), destinationFolderName: d.lastPathComponent)
        case .trash(let u), .delete(let u), .duplicate(let u), .setAttributes(let u, _), .setCustomIcon(let u, _),
             .compress(let u, _):
            return JobDescription(verb: verb, itemCount: u.count, firstItemName: u.first?.lastPathComponent,
                                  sourceFolderName: folderName(u.first), destinationFolderName: nil)
        case .newItem(_, let d):
            return JobDescription(verb: verb, itemCount: 1, firstItemName: nil, sourceFolderName: nil, destinationFolderName: d.lastPathComponent)
        case .rename(let u, _), .chmodRecursive(let u, _), .extract(let u):
            return JobDescription(verb: verb, itemCount: 1, firstItemName: u.lastPathComponent,
                                  sourceFolderName: folderName(u), destinationFolderName: nil)
        case .undo(let r), .redo(let r):
            return JobDescription(verb: verb, itemCount: r.actions.count, firstItemName: r.actions.first?.urls.first?.lastPathComponent,
                                  sourceFolderName: nil, destinationFolderName: nil)
        }
    }
}

public struct JobRequest: Sendable {
    public var kind: JobKind
    public var origin: OriginID?
    public var registersUndo: Bool
    public init(_ kind: JobKind, origin: OriginID? = nil, registersUndo: Bool = true) {
        self.kind = kind; self.origin = origin; self.registersUndo = registersUndo
    }
}

public enum JobState: Sendable, Equatable { case queued, planning, running, paused, waitingForUser, cancelling, finished }

public enum JobVerb: String, Sendable, Codable {
    case copying, moving, trashing, deleting, duplicating, creating, renaming, makingAlias, makingSymlink,
         changingPermissions, changingAttributes, changingIcon, compressing, extracting, undoing, redoing
}

/// UI formats "Copying 1,204 items from Downloads to Backup".
public struct JobDescription: Sendable, Equatable, Codable {
    public var verb: JobVerb
    public var itemCount: Int
    public var firstItemName: String?
    public var sourceFolderName: String?
    public var destinationFolderName: String?
    public init(verb: JobVerb, itemCount: Int, firstItemName: String?, sourceFolderName: String?, destinationFolderName: String?) {
        self.verb = verb; self.itemCount = itemCount; self.firstItemName = firstItemName
        self.sourceFolderName = sourceFolderName; self.destinationFolderName = destinationFolderName
    }
}

public struct JobSnapshot: Sendable, Identifiable, Equatable {
    public var id: JobID
    public var description: JobDescription
    public var state: JobState
    public var progress: JobProgress
    public var origin: OriginID?
    public var startedAt: ContinuousClock.Instant
    public init(id: JobID, description: JobDescription, state: JobState, progress: JobProgress,
                origin: OriginID?, startedAt: ContinuousClock.Instant) {
        self.id = id; self.description = description; self.state = state
        self.progress = progress; self.origin = origin; self.startedAt = startedAt
    }
}

/// `.<name>.macx-partial-<job.short>`, truncating the name (on a character boundary) to stay within 255 bytes.
enum PartialName {
    static let marker = ".macx-partial-"
    static func make(for name: String, job: JobID) -> String {
        let suffix = marker + job.short
        var base = name
        while ("." + base + suffix).utf8.count > 255 { base.removeLast() }
        return "." + base + suffix
    }
    static func isPartial(_ lastComponent: String) -> Bool {
        lastComponent.wholeMatch(of: /\..+\.macx-partial-[0-9a-f]{8}/) != nil
    }
}
