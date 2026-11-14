import Foundation
import Core
import MacxFS
import MacxPluginKit

/// Paste or in-app drop of remote items into a local folder (spec §4.5): a "Downloading …" row while the items
/// download into `<state dir>/remote-staging/<uuid>/`, then a normal copy job (conflicts, progress, undo), then the
/// staging folder is removed. Remote destinations are refused (nil).
@MainActor
enum RemoteTransfer {
    @MainActor private final class TaskBox { var task: Task<Bool, Never>? }

    @discardableResult
    static func copy(_ sources: [URL], into destination: URL, environment: CoreEnvironment, origin: OriginID?) -> Task<Bool, Never>? {
        guard !sources.isEmpty, destination.isFileURL else { return nil }
        let operations = environment.operations
        let export = RemoteExport(registry: environment.remote,
                                  stagingRoot: environment.statePaths.root.appending(path: "remote-staging", directoryHint: .isDirectory))
        let first = RemoteLocation(url: sources[0])
        let description = JobDescription(verb: .downloading, itemCount: sources.count, firstItemName: first?.name ?? first?.repo,
                                         sourceFolderName: first.flatMap { environment.remote.provider(id: $0.provider)?.displayRoot($0) },
                                         destinationFolderName: destination.lastPathComponent)
        let box = TaskBox()
        let id = operations.beginExternal(description, cancel: { box.task?.cancel() })
        let lanes = environment.lanes
        let task = Task { @MainActor () -> Bool in
            let staged: RemoteExport.Staged
            do {
                staged = try await export.stage(sources) { p in
                    Task { @MainActor in
                        var progress = JobProgress()
                        progress.itemsDone = p.itemsDone
                        progress.bytesDone = p.bytesDone
                        progress.currentItem = p.currentItem
                        operations.updateExternal(id, progress)
                    }
                }
            } catch {
                operations.endExternal(id)
                return false
            }
            operations.endExternal(id)
            _ = await operations.perform(JobRequest(.copy(sources: staged.items, destination: destination), origin: origin))
            let directory = staged.directory
            _ = try? await lanes.perform(on: .unknown, .fileOp) { _ in try? FileManager.default.removeItem(at: directory) }
            return true
        }
        box.task = task
        return task
    }
}
