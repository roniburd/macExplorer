import Foundation
import MacxFS

/// Cancellable recursive folder-size scan (§11 Phase 2, §4.2). Runs on a `.scan` lane inside
/// `withNoMaterialization`, with an iterative directory stack and one `BulkReader.read` per directory.
/// Symlinks and aliases count as themselves and are never followed; hard links count once per scan;
/// other volumes' mount points are not crossed; dataless, degraded and unreadable parts mark `isPartial`.
public enum FolderSizeScanner {
    struct ScanState {
        var result = FolderSize()
        var pending: [URL] = []
        var seenHardLinks = Set<UInt64>()
        let mountPoints: Set<String>          // other volumes' mount points, MountTable.standardize'd
        init(mountPoints: Set<String>) { self.mountPoints = mountPoints }
    }

    /// Nil when the lane job is cancelled. `onDirectory` receives the number of directories visited so far.
    public static func scan(_ root: URL, context: LaneContext, mountTable: MountTable,
                            types: TypeRegistry = .shared, onDirectory: ((Int) -> Void)? = nil) -> FolderSize? {
        assertOffMain()
        return withNoMaterialization { () -> FolderSize? in
            let rootVolume = mountTable.volume(containing: path(of: root))?.id
            let others = Set(mountTable.volumes.filter { $0.id != rootVolume }.map { path(of: $0.mountPoint) })
            var state = ScanState(mountPoints: others)
            state.pending = [root]
            var visited = 0
            var options = ReadOptions()
            options.noMaterialization = true
            options.batchSize = 4_096
            while let directory = state.pending.popLast() {
                if context.isCancelled { return nil }
                context.heartbeat()
                do throws(ReadFailure) {
                    _ = try BulkReader.read(directory, generation: .initial, options: options, types: types,
                                            context: context) { batch in
                        accumulate(batch, in: directory, state: &state)
                        return !context.isCancelled
                    }
                } catch {
                    // Unreadable (EACCES) or vanished (ENOENT race) folder: its contents are missing.
                    state.result.isPartial = true
                }
                visited += 1
                onDirectory?(visited)
            }
            return context.isCancelled ? nil : state.result
        }
    }

    static func accumulate(_ batch: Batch, in directory: URL, state: inout ScanState) {
        for i in 0..<batch.count {
            let e = batch.entries[i]
            if e.flags.contains(.degraded) { state.result.isPartial = true }
            switch e.kind {
            case .directory, .package:
                state.result.folders += 1
                if e.flags.contains(.dataless) { state.result.isPartial = true; continue }
                let child = directory.appending(path: batch.name(at: i), directoryHint: .isDirectory)
                if state.mountPoints.contains(path(of: child)) { continue }   // another volume: not partial
                state.pending.append(child)
            case .file, .symlink, .alias, .other:
                if e.flags.contains(.hasHardLinks), !state.seenHardLinks.insert(e.fileID).inserted { continue }
                state.result.files += 1
                state.result.bytes += e.size
                state.result.allocatedBytes += e.allocSize
            }
        }
        if !batch.errors.isEmpty { state.result.isPartial = true }
    }

    static func path(of url: URL) -> String {
        MountTable.standardize(url.path(percentEncoded: false))
    }
}
