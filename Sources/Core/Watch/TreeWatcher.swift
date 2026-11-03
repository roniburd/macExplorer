import Darwin
import Foundation
import Synchronization

/// Watches expanded Folders-tree nodes non-recursively (§4.3 Tree nodes): one vnode DispatchSource
/// (.write | .delete | .rename | .link) on an O_EVTONLY fd per directory, capped at `sourceCap`.
/// fds are opened and closed on a private queue, never on main.
@MainActor
public final class TreeWatcher {
    public static let sourceCap = 256

    /// One watched node. The source is created on `queue`; `cancelled` covers an unwatch that beats the open.
    private final class Node: Sendable {
        let url: URL
        private let source = Mutex<(any DispatchSourceFileSystemObject)?>(nil)
        private let cancelled = Mutex(false)
        init(url: URL) { self.url = url }

        func open(on queue: DispatchQueue, onChange: @escaping @Sendable () -> Void) {
            let fd = Darwin.open(url.path(percentEncoded: false), O_EVTONLY | O_DIRECTORY | O_CLOEXEC)
            guard fd >= 0 else { return }
            let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename, .link],
                                                              queue: queue)
            s.setEventHandler(handler: onChange)
            s.setCancelHandler { Darwin.close(fd) }
            let keep = cancelled.withLock { c -> Bool in
                guard !c else { return false }
                source.withLock { $0 = s }
                return true
            }
            if keep { s.resume() } else { s.cancel(); s.resume() }
        }

        func cancel() {
            cancelled.withLock { $0 = true }
            source.withLock { s in
                s?.cancel()
                s = nil
            }
        }
    }

    private let onChange: @MainActor (URL) -> Void
    private let queue = DispatchQueue(label: "macx.tree-watcher", qos: .utility)
    private var nodes: [String: Node] = [:]

    public init(onChange: @escaping @MainActor (URL) -> Void) { self.onChange = onChange }

    /// A resumed vnode source lives until cancelled: close every fd with the watcher.
    isolated deinit {
        for node in nodes.values { node.cancel() }
    }

    public var count: Int { nodes.count }

    /// false when over the cap or the volume is not local: caller re-reads on re-expand / window key.
    @discardableResult
    public func watch(_ directory: URL, isLocalVolume: Bool) -> Bool {
        guard isLocalVolume else { return false }
        let key = Self.key(directory)
        if nodes[key] != nil { return true }
        guard nodes.count < Self.sourceCap else { return false }
        let node = Node(url: directory)
        nodes[key] = node
        let url = directory, queue = self.queue
        queue.async { [weak self] in
            node.open(on: queue) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.nodes[key] === node else { return }
                    self.onChange(url)
                }
            }
        }
        return true
    }

    public func unwatch(_ directory: URL) {
        nodes.removeValue(forKey: Self.key(directory))?.cancel()
    }

    /// Before an unmount: every node at or below the mount point.
    public func unwatchAll(under volumeMountPoint: URL) {
        let root = Self.key(volumeMountPoint)
        let prefix = root == "/" ? "/" : root + "/"
        for key in nodes.keys where key == root || key.hasPrefix(prefix) {
            nodes.removeValue(forKey: key)?.cancel()
        }
    }

    private static func key(_ url: URL) -> String { ChangeBus.key(for: url) }
}
