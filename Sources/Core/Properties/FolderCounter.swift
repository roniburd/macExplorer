import Darwin
import Foundation
import MacxFS
import Synchronization

public struct CountProgress: Sendable, Equatable {
    public var files: Int
    public var folders: Int
    public var bytes: Int64                 // logical bytes of everything that is not a folder
    public var finished: Bool
    /// Allocated bytes of everything counted (Size on disk).
    public var diskBytes: Int64
    /// Subfolders whose contents couldn't be read: the totals undercount (QA round 2).
    public var unreadableFolders: Int
    /// The folder itself couldn't be read (or is gone): the totals say nothing about it.
    public var rootUnreadable: Bool
    public init(files: Int, folders: Int, bytes: Int64, finished: Bool, diskBytes: Int64 = 0,
                unreadableFolders: Int = 0, rootUnreadable: Bool = false) {
        self.files = files
        self.folders = folders
        self.bytes = bytes
        self.finished = finished
        self.diskBytes = diskBytes
        self.unreadableFolders = unreadableFolders
        self.rootUnreadable = rootUnreadable
    }
}

public enum FolderCounter {
    /// fts(FTS_PHYSICAL|FTS_XDEV) under no-materialization on a read lane; ~10 Hz updates; cancel by
    /// ending iteration or cancelling the consuming Task. Never follows symlinks. Counts the folder's contents, not the
    /// folder itself (S5 Contract note 10: F/{a,b,sub/c} → files 3, folders 1).
    public static func count(_ url: URL, lanes: LanePool, volume: VolumeID) -> AsyncStream<CountProgress> {
        count(url, lanes: lanes, volume: volume, interval: .milliseconds(100))
    }

    /// `interval` between intermediate updates (`.zero`: one per entry, for tests). The last element is the only one
    /// with `finished == true`; a cancelled or failed count ends without it.
    static func count(_ url: URL, lanes: LanePool, volume: VolumeID, interval: Duration) -> AsyncStream<CountProgress> {
        let (stream, continuation) = AsyncStream<CountProgress>.makeStream()
        let stop = StopFlag()
        let path = url.path(percentEncoded: false)
        let task = Task {
            let final = try? await lanes.perform(on: volume, .read) { context in
                withNoMaterialization {
                    walk(path, interval: interval, shouldStop: { stop.isSet || context.isCancelled },
                         heartbeat: { context.heartbeat() }, progress: { continuation.yield($0) })
                }
            }
            if let final, !stop.isSet { continuation.yield(final) }
            continuation.finish()
        }
        continuation.onTermination = { _ in
            stop.set()
            task.cancel()
        }
        return stream
    }

    /// Synchronous walk of `path`'s contents; lane only. Returns the finished total, or nil when stopped.
    /// Symlinks (also loops) count once as items and are never followed; unreadable folders count, their contents don't
    /// (`unreadableFolders` says so; `rootUnreadable` when the folder itself can't be read or is gone).
    static func walk(_ path: String, interval: Duration = .milliseconds(100), shouldStop: () -> Bool = { false },
                     heartbeat: () -> Void = {}, progress: (CountProgress) -> Void = { _ in }) -> CountProgress? {
        assertOffMain()
        var total = CountProgress(files: 0, folders: 0, bytes: 0, finished: false)
        guard let cPath = strdup(path) else { return finished(total) }
        defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else { return finished(total) }
        defer { fts_close(fts) }
        let clock = ContinuousClock()
        var next = clock.now + interval
        var visited = 0
        while let entry = fts_read(fts) {
            if shouldStop() { return nil }
            let e = entry.pointee
            let info = Int32(e.fts_info)
            guard e.fts_level > 0 else {                      // the folder itself: not counted, but must be readable
                if info == FTS_DNR || info == FTS_ERR || info == FTS_NS { total.rootUnreadable = true }
                continue
            }
            switch info {
            case FTS_D, FTS_DC:
                total.folders += 1
                if let st = e.fts_statp { total.diskBytes += Int64(st.pointee.st_blocks) * 512 }
            case FTS_DNR, FTS_ERR:
                total.unreadableFolders += 1                  // DNR follows the FTS_D already counted
                continue
            case FTS_DP:
                continue
            case FTS_NS:
                total.files += 1
            default:
                total.files += 1
                if let st = e.fts_statp {
                    total.bytes += Int64(st.pointee.st_size)
                    total.diskBytes += Int64(st.pointee.st_blocks) * 512
                }
            }
            visited += 1
            if visited & 0xFF == 0 { heartbeat() }
            if clock.now >= next {
                heartbeat()
                progress(total)
                next = clock.now + interval
            }
        }
        return finished(total)
    }

    private static func finished(_ progress: CountProgress) -> CountProgress {
        var done = progress
        done.finished = true
        return done
    }
}

private final class StopFlag: Sendable {
    private let value = Atomic<Bool>(false)
    var isSet: Bool { value.load(ordering: .relaxed) }
    func set() { value.store(true, ordering: .relaxed) }
}
