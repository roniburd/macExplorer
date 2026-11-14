import AppKit
import Core
import MacxFS
import MacxPluginKit

/// Paste or in-app drop of remote items into a local folder (spec §4.5): a "Downloading …" row while the items
/// download into `<state dir>/remote-staging/<uuid>/`, then a normal copy job (conflicts, progress, undo), then the
/// staging folder is removed. Remote destinations are refused (nil). A failed download is reported through `report`
/// (by default an alert on `window`); a cancelled one ends quietly.
@MainActor
enum RemoteTransfer {
    @MainActor private final class TaskBox { var task: Task<Bool, Never>? }

    /// Why a download failed, as the alert shows it.
    struct Failure: Equatable {
        let title: String
        let detail: String?
    }

    @discardableResult
    static func copy(_ sources: [URL], into destination: URL, environment: CoreEnvironment, origin: OriginID?,
                     window: NSWindow? = nil,
                     report: @escaping @MainActor (Failure, NSWindow?) -> Void = RemoteTransfer.presentAlert) -> Task<Bool, Never>? {
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
                if !(error is CancellationError), !Task.isCancelled {
                    let provider = first.flatMap { environment.remote.provider(id: $0.provider)?.displayName }
                    report(failure(error, sources: sources, provider: provider), window)
                }
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

    static func failure(_ error: any Error, sources: [URL], provider: String?) -> Failure {
        let name = RemoteLocation(url: sources[0]).map { $0.name ?? $0.repo } ?? sources[0].lastPathComponent
        let title = sources.count == 1 ? String(format: L10n.string("Couldn't download '%@'"), name)
                                       : String(format: L10n.string("Couldn't download %lld items"), Int64(sources.count))
        let host = provider ?? L10n.string("The repository")
        guard let remote = error as? RemoteError else { return Failure(title: title, detail: error.localizedDescription) }
        switch remote {
        case .notFound:
            return Failure(title: title, detail: L10n.string("It no longer exists in the repository."))
        case .noAccess:
            return Failure(title: title, detail: String(format: L10n.string("%@ refused access."), host))
        case .rateLimited(let resetAt?):
            let time = DateFormatter.localizedString(from: resetAt, dateStyle: .none, timeStyle: .short)   // local zone
            return Failure(title: title, detail: String(format: L10n.string("%@ rate limit reached — resets at %@"), host, time))
        case .rateLimited(nil):
            return Failure(title: title, detail: String(format: L10n.string("%@ rate limit reached — try again later"), host))
        case .network(let message):
            let reach = String(format: L10n.string("Can't reach %@"), host)
            return Failure(title: title, detail: message.isEmpty ? reach : reach + " (" + message + ")")
        case .unsupported:
            return Failure(title: title, detail: String(format: L10n.string("%@ can't download this item."), host))
        @unknown default:
            return Failure(title: title, detail: error.localizedDescription)
        }
    }

    /// A warning sheet on `window` (app-modal without one), like the operations UI's job errors.
    static func presentAlert(_ failure: Failure, window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = failure.title
        alert.informativeText = failure.detail ?? ""
        alert.addButton(withTitle: L10n.string("OK"))
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}
