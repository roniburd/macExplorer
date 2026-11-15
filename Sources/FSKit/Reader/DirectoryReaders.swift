import Darwin
import Foundation
import Synchronization

/// One DirectoryReader per volume, chosen by the in-memory mount table.
public final class DirectoryReaders: Sendable {
    private let lanes: LanePool
    private let mountTable: MountTableStore
    private let types: TypeRegistry
    private let readers = Mutex<[VolumeID: DirectoryReader]>([:])

    /// Remote URLs are never read here (RemoteListingSource lists them); a stray caller gets ENOTSUP, not a POSIX
    /// read of "/owner%2Frepo@main/…".
    private let remoteRefusal: DirectoryReader

    public init(lanes: LanePool, mountTable: MountTableStore, types: TypeRegistry = .shared) {
        self.lanes = lanes
        self.mountTable = mountTable
        self.types = types
        self.remoteRefusal = DirectoryReader(volume: VolumeID(raw: "remote:refused"), lanes: lanes, types: types) { _, _, _, _, _, _ in
            throw ReadFailure(code: ENOTSUP, stage: .open)
        }
    }

    /// By MountTable volume, else VolumeID.unknown. Remote URLs: a reader whose read and readItems
    /// both fail with ENOTSUP (readItems via ItemReader's remote guard).
    public func reader(for directory: URL) -> DirectoryReader {
        if RemoteScheme.isRemote(directory) { return remoteRefusal }
        return reader(for: mountTable.current().volume(containing: directory.path(percentEncoded: false))?.id ?? .unknown)
    }

    /// As `reader(for:)`, but by the volume the directory really is on once symlinks in its path are followed, so a
    /// path through a link into another volume (~/nas → /Volumes/NAS) reads on that volume's lanes, and a hung share
    /// never stalls or poisons the lanes of the volume the link lives on. Resolution runs on a read lane of the path's
    /// textual volume and stops at the first mount point it would enter (`resolveSymlinks`). Resolved on every call, never
    /// cached: a link can be retargeted while the same volumes stay mounted. If the lane call fails (the caller was
    /// cancelled, the textual volume is unresponsive), this call uses the textual volume.
    public func reader(resolving directory: URL) async -> DirectoryReader {
        if RemoteScheme.isRemote(directory) { return remoteRefusal }
        let table = mountTable.current()
        let path = directory.path(percentEncoded: false)
        let textual = table.volume(containing: path)?.id ?? .unknown
        guard !table.volumes.isEmpty,
              let real = try? await lanes.perform(on: textual, .read, { _ in DirectoryReaders.resolveSymlinks(path, in: table) })
        else { return reader(for: textual) }
        return reader(for: table.volume(containing: real)?.id ?? .unknown)
    }

    /// `path` with symlinks followed (".." applied to the resolved prefix, as the kernel does), but only on the volume
    /// the walk is on: before it would look at a component on another volume of `table` (a mount point), it stops and
    /// appends the rest as written, so it never touches a possibly hung mount. Missing components are appended as-is.
    /// Returns `path` unchanged for a relative path or more than 32 links. Off main (lstat/readlink).
    static func resolveSymlinks(_ path: String, in table: MountTable) -> String {
        assertOffMain()
        guard path.hasPrefix("/") else { return path }
        var current = ""
        var rest = path.split(separator: "/").map(String.init)
        var links = 0
        while !rest.isEmpty {
            let component = rest.removeFirst()
            if component == "." { continue }
            if component == ".." {
                current = (current as NSString).deletingLastPathComponent
                if current == "/" { current = "" }
                continue
            }
            let next = current + "/" + component
            let here = table.volume(containing: current.isEmpty ? "/" : current)?.id
            guard table.volume(containing: next)?.id == here else {
                return ([next] + rest).joined(separator: "/")
            }
            var st = stat()
            guard lstat(next, &st) == 0 else {
                return ([next] + rest).joined(separator: "/")
            }
            guard (st.st_mode & S_IFMT) == S_IFLNK else { current = next; continue }
            links += 1
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let n = readlink(next, &buffer, Int(PATH_MAX))
            guard links <= 32, n >= 0 else { return path }
            let target = String(decoding: buffer[0..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if target.hasPrefix("/") { current = "" }
            rest = target.split(separator: "/").map(String.init) + rest
        }
        return current.isEmpty ? "/" : current
    }

    public func reader(for volume: VolumeID) -> DirectoryReader {
        readers.withLock { map in
            if let existing = map[volume] { return existing }
            let created = DirectoryReader(volume: volume, lanes: lanes, types: types)
            map[volume] = created
            return created
        }
    }

    public func cancelAll(on volume: VolumeID) async {
        guard let reader = readers.withLock({ $0[volume] }) else { return }
        await reader.cancelAll()
    }
}
