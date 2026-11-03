import Foundation

/// A coalesced change notice for the visible folder (§4.3 Watcher).
public enum WatchEvent: Sendable, Equatable {
    case items([String])     // ≤256 names directly inside the folder, coalesced
    case fullRescan          // >256, MustScanSubDirs (folder or ancestor), UserDropped, KernelDropped, EventIdsWrapped
    case rootChanged         // RootChanged / ItemRemoved|ItemRenamed on the folder itself
}

/// One FSEvents record before classification.
public struct RawFSEvent: Sendable, Equatable {
    public var path: String
    public var flags: UInt32       // FSEventStreamEventFlags
    public var id: UInt64
    public init(path: String, flags: UInt32, id: UInt64) {
        self.path = path
        self.flags = flags
        self.id = id
    }
}

/// The content watcher a FolderModel starts after its first read (P1-11 provides the FSEvents one).
public protocol ContentWatching: AnyObject, Sendable {
    func start()
    func stop()
    var lastEventID: UInt64 { get }
}

/// Watches nothing: lastEventID 0; start/stop do nothing.
public final class NoopWatcher: ContentWatching {
    public init() {}
    public func start() {}
    public func stop() {}
    public var lastEventID: UInt64 { 0 }
}
