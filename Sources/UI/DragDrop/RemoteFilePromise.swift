import AppKit
import Core
import MacxPluginKit
import UniformTypeIdentifiers

/// Reads the private remote-items type: a ⌘C in a repository folder or one of our own remote drags.
@MainActor
enum RemoteItemsPasteboard {
    static let type = NSPasteboard.PasteboardType(SystemPasteboard.remoteItemsType)

    static func read(_ pasteboard: NSPasteboard) -> [URL] {
        guard pasteboard.types?.contains(type) == true else { return [] }
        return (pasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: type).flatMap(URL.init(string:)) }
    }
}

/// One dragged remote item (spec §4.5): a file promise other apps (Finder) resolve on drop, which downloads then,
/// plus the remote URL under the private type, so a drop on our own folders goes through `RemoteTransfer`.
final class RemoteFilePromiseProvider: NSFilePromiseProvider {
    let remoteURL: URL
    /// NSFilePromiseProvider's `delegate` is weak; the promise must still be answerable after the drag ended.
    private let retainedDelegate: any NSFilePromiseProviderDelegate

    init(remoteURL: URL, fileType: String, delegate: any NSFilePromiseProviderDelegate) {
        self.remoteURL = remoteURL
        self.retainedDelegate = delegate
        super.init()
        self.fileType = fileType
        self.delegate = delegate
    }

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [NSPasteboard.PasteboardType(SystemPasteboard.remoteItemsType)]
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type.rawValue == SystemPasteboard.remoteItemsType ? remoteURL.absoluteString : super.pasteboardPropertyList(forType: type)
    }

    static func fileType(for item: RemoteItem) -> String {
        if item.kind == .directory { return UTType.folder.identifier }
        let ext = (item.name as NSString).pathExtension
        return UTType(filenameExtension: ext)?.identifier ?? UTType.data.identifier
    }
}

/// Writes promised remote items where the receiving app asks, off the main thread.
final class RemoteFilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate, Sendable {
    private let registry: ProviderRegistry
    private static let queue: OperationQueue = {
        let q = OperationQueue()
        q.qualityOfService = .userInitiated
        return q
    }()

    @MainActor init(environment: CoreEnvironment) { self.registry = environment.remote }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (provider as? RemoteFilePromiseProvider).flatMap { RemoteLocation(url: $0.remoteURL)?.name } ?? "item"
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { Self.queue }

    /// Downloads into a temporary folder and moves the result to `url` only when complete (`RemoteExport.download`),
    /// so a failure leaves nothing half-written in the drop folder. The write is published as a file `Progress` on
    /// `url`, so the receiving app (Finder) shows it and can cancel it.
    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
        guard let remote = (provider as? RemoteFilePromiseProvider)?.remoteURL, let location = RemoteLocation(url: remote) else {
            return completionHandler(RemoteError.notFound)
        }
        let registry = self.registry
        let progress = Progress(totalUnitCount: -1)
        progress.kind = .file
        progress.fileOperationKind = .downloading
        progress.fileURL = url
        progress.isCancellable = true
        progress.publish()          // before the task starts, so its unpublish always comes after
        let task = Task {
            defer { progress.unpublish() }
            do {
                let item = try await registry.item(at: location)
                if let size = item.size, item.kind == .file { progress.totalUnitCount = size }
                try await RemoteExport(registry: registry, stagingRoot: url.deletingLastPathComponent())
                    .download(location, item: item, to: url) { p in
                        if progress.totalUnitCount > 0 { progress.completedUnitCount = p.bytesDone }
                    }
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
        progress.cancellationHandler = { task.cancel() }
        if progress.isCancelled { task.cancel() }
    }
}

/// "Open on <provider>": opens the items' web URLs (ExternalOpeners keeps sandboxed runs off real browsers).
@MainActor
final class RemoteMenuTarget: NSObject {
    static let shared = RemoteMenuTarget()
    /// Set by ContextMenuBuilder from the launch options (records instead of opening in sandboxed runs).
    var opener: any ExternalURLOpening = WorkspaceURLOpener()
    @objc func open(_ sender: NSMenuItem) {
        for url in (sender.representedObject as? [URL]) ?? [] { opener.open(url) }
    }
}
