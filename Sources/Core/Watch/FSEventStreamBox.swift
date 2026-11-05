import CoreServices
import Darwin
import Foundation

/// The FSEventStream plumbing `Watcher` and `SubtreeWatcher` share: create, schedule on a private serial queue,
/// start, stop, invalidate and release. `open` and `close` run on `queue` only, never on main.
///
/// Concurrency escape (moved here from Watcher.swift): `stream` is `nonisolated(unsafe)` because FSEventStreamRef is
/// not Sendable. It is confined to `queue`: only `open` and `close` (both `dispatchPrecondition`-checked) touch it,
/// plus `deinit`, which runs when no other reference to the box exists.
final class FSEventStreamBox: Sendable {
    /// Context info for the C callback; holds the receiver weakly (through `deliver`) so a live stream never
    /// keeps its watcher alive.
    private final class Callback: Sendable {
        let deliver: @Sendable ([RawFSEvent]) -> Void
        init(_ deliver: @escaping @Sendable ([RawFSEvent]) -> Void) { self.deliver = deliver }
    }

    let queue: DispatchQueue
    /// Only touched on `queue` (and in deinit, when nothing else can reach it).
    nonisolated(unsafe) private var stream: FSEventStreamRef?

    init(label: String) { queue = DispatchQueue(label: label, qos: .utility) }

    deinit {
        // close() normally ran; a dropped box must not leave a stream behind.
        if let stream { Self.teardown(stream) }
    }

    /// On `queue`. Paths arrive as real paths (FSEvents resolves symlinks); `deliver` runs on `queue`.
    /// `kFSEventStreamCreateFlagUseCFTypes` is always added. false when the stream could not be created or started.
    func open(path: String, since: UInt64, latency: Duration, flags: Int,
              deliver: @escaping @Sendable ([RawFSEvent]) -> Void) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        let callback = Callback(deliver)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passRetained(callback).toOpaque(), retain: nil,
                                           release: { info in
                                               if let info { Unmanaged<Callback>.fromOpaque(info).release() }
                                           }, copyDescription: nil)
        let createFlags = FSEventStreamCreateFlags(flags | kFSEventStreamCreateFlagUseCFTypes)
        let sinceWhen = since == 0 ? FSEventStreamEventId(kFSEventStreamEventIdSinceNow) : since
        let seconds = Double(latency.components.seconds) + Double(latency.components.attoseconds) / 1e18
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, { _, info, count, paths, flags, ids in
            guard let info else { return }
            let callback = Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self)
            var events: [RawFSEvent] = []
            events.reserveCapacity(count)
            for i in 0..<count {
                guard let path = array[i] as? String else { continue }
                events.append(RawFSEvent(path: path, flags: flags[i], id: ids[i]))
            }
            callback.deliver(events)
        }, &context, [path] as CFArray, sinceWhen, seconds, createFlags) else { return false }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return false
        }
        self.stream = stream
        return true
    }

    /// On `queue`. Idempotent.
    func close() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let stream else { return }
        self.stream = nil
        Self.teardown(stream)
    }

    private static func teardown(_ stream: FSEventStreamRef) {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    /// realpath(3) of `path`, or `path` when it cannot be resolved. Off main (a file-system call).
    static func realPath(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buffer) != nil else { return path }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }
}
