import Foundation
import Darwin
import MacxFS

/// The folder's inode number, for `FolderViewLocator.fileID`. Runs on a read lane under no-materialization (§4.2),
/// never on main.
public enum FolderIdentityProbe {
    /// `stat` (following a final symlink, so the key is the folder shown, not the link) `st_ino`; nil on error.
    public static func fileID(of url: URL, lanes: LanePool, volume: VolumeID) async -> UInt64? {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        let result = try? await lanes.perform(on: volume, .read) { _ -> UInt64? in
            assertOffMain()
            return withNoMaterialization { () -> UInt64? in
                var st = stat()
                guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return nil }
                return UInt64(st.st_ino)
            }
        }
        return result ?? nil
    }
}

extension FinderFolderView {
    /// `read(folder:globalColumns:)` on a read lane under no-materialization (§4.2): never on main, never writes, and
    /// a dataless `.DS_Store` is not downloaded. nil when Finder recorded nothing (or the read failed).
    public static func read(folder url: URL, globalColumns: [ColumnSetting], lanes: LanePool, volume: VolumeID) async
        -> FolderViewSettings? {
        let result = try? await lanes.perform(on: volume, .read) { _ -> FolderViewSettings? in
            assertOffMain()
            return withNoMaterialization { read(folder: url, globalColumns: globalColumns) }
        }
        return result ?? nil
    }
}
