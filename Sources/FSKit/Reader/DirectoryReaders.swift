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

    /// By MountTable volume, else VolumeID.unknown. Remote URLs: a reader that fails every read with ENOTSUP.
    public func reader(for directory: URL) -> DirectoryReader {
        if RemoteScheme.isRemote(directory) { return remoteRefusal }
        return reader(for: mountTable.current().volume(containing: directory.path(percentEncoded: false))?.id ?? .unknown)
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
