// Sources/UI/DragDrop/DropTarget.swift
import AppKit
import Core
import MacxFS

extension DragModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        var modifiers: DragModifiers = []
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.control) { modifiers.insert(.control) }
        self.init(rawValue: modifiers.rawValue)
    }
}

/// Only folders spring open; packages are files (§5.7).
enum SpringLoadPolicy {
    static func opens(_ kind: Kind) -> Bool { kind == .directory }
}

/// Which folder a list drop lands in (Review Focus 4): onto a folder row → that folder; anything else (a file,
/// alias, symlink or package row, between rows, empty space) → the displayed folder.
enum DropRetarget {
    struct Result: Equatable { var url: URL; var retargetToFolder: Bool }

    @MainActor
    static func destination(row: Int, onRow: Bool, folder: FolderModel) -> Result {
        if onRow, row >= 0, row < folder.rowCount, folder.entry(atRow: row).kind == .directory {
            return Result(url: folder.url(atRow: row), retargetToFolder: false)
        }
        return Result(url: folder.directory, retargetToFolder: true)
    }
}

/// Scenario `drop.onto` strings (overview §3.14): "" current folder, a row name, "sidebar:<Favorite name>", "crumb:<index>".
@MainActor
enum DropDestinationResolver {
    static func resolve(_ onto: String, folder: FolderModel, favorites: [Favorite]) -> URL? {
        if onto.isEmpty { return folder.directory }
        if onto.hasPrefix("sidebar:") {
            let name = String(onto.dropFirst("sidebar:".count))
            return favorites.first { $0.displayName == name }.map { URL(filePath: $0.lastKnownPath, directoryHint: .isDirectory) }
        }
        if onto.hasPrefix("crumb:"), let index = Int(onto.dropFirst("crumb:".count)) {
            return crumbURL(index, of: folder.directory, volumeRoot: folder.volume?.mountPoint)
        }
        guard let row = folder.row(named: onto) else { return nil }
        return DropRetarget.destination(row: row, onRow: true, folder: folder).url
    }

    /// Breadcrumb segment `index`: 0 is the volume root, then one segment per path component below it (§5.2).
    static func crumbURL(_ index: Int, of directory: URL, volumeRoot: URL?) -> URL? {
        let root = (volumeRoot ?? URL(filePath: "/", directoryHint: .isDirectory)).standardizedFileURL
        let rootComponents = root.pathComponents
        let components = directory.standardizedFileURL.pathComponents
        guard components.starts(with: rootComponents), index >= 0, index <= components.count - rootComponents.count else { return nil }
        var url = root
        for component in components[rootComponents.count..<(rootComponents.count + index)] {
            url.append(path: component, directoryHint: .isDirectory)
        }
        return url
    }
}

/// Shared drop destination logic for lists, tree, favorites and breadcrumb segments (§5.6).
/// draggingUpdated is purely in memory: the pasteboard is read once per drag session, and DropPolicy uses the mount table.
@MainActor
final class DropTarget {
    static let acceptedTypes: [NSPasteboard.PasteboardType] =
        [.fileURL, DragPasteboard.filenamesType] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    private static let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    private let context: UIContext
    private weak var originView: NSView?
    private var cachedSequence: Int?
    private var cachedURLs: [URL] = []
    /// Seam for tests; the default pops DropMenu at the drop point.
    var presentMenu: @MainActor (NSPoint, NSView) -> DropChoice? = DropMenu.run

    init(context: UIContext, originView: NSView? = nil) {
        self.context = context
        self.originView = originView
    }

    var origin: OriginID? { originView?.window.map { OriginID(raw: $0.windowNumber) } }

    func operation(sources: [URL], destination: URL, modifiers: DragModifiers, secondary: Bool) -> DragOperation {
        guard !sources.isEmpty else { return .none }
        return DropPolicy.operation(sources: sources.map { $0.standardizedFileURL.path },
                                    destination: destination.standardizedFileURL.path, modifiers: modifiers,
                                    isSecondaryDrag: secondary, mountTable: context.environment.volumes.mountTable)
    }

    func validate(_ info: any NSDraggingInfo, destination: URL) -> NSDragOperation {
        if Self.isPromiseOnly(info.draggingPasteboard) { return .copy }
        let urls = sources(info)
        let op = operation(sources: urls, destination: destination, modifiers: DragModifiers(NSEvent.modifierFlags),
                           secondary: DragPasteboard.isSecondary(info.draggingPasteboard))
        info.numberOfValidItemsForDrop = op == .none ? 0 : urls.count
        return Self.dragOperation(op)
    }

    func perform(_ info: any NSDraggingInfo, destination: URL, in view: NSView) -> Bool {
        if Self.isPromiseOnly(info.draggingPasteboard) { return receivePromises(info.draggingPasteboard, destination: destination) }
        let urls = sources(info)
        let op = operation(sources: urls, destination: destination, modifiers: DragModifiers(NSEvent.modifierFlags),
                           secondary: DragPasteboard.isSecondary(info.draggingPasteboard))
        return run(op, sources: urls, destination: destination, menuAt: view.convert(info.draggingLocation, from: nil), in: view)
    }

    @discardableResult
    func run(_ op: DragOperation, sources: [URL], destination: URL, menuAt point: NSPoint, in view: NSView?) -> Bool {
        let choice: DropChoice?
        switch op {
        case .none: return false
        case .menu:
            guard let view else { return false }
            choice = presentMenu(point, view)
        default:
            choice = DropChoice(operation: op)
        }
        guard let choice, let kind = choice.jobKind(sources: sources, destination: destination) else { return false }
        let request = JobRequest(kind, origin: origin)
        let operations = context.environment.operations
        Task { _ = await operations.perform(request) }
        return true
    }

    static func dragOperation(_ op: DragOperation) -> NSDragOperation {
        switch op {
        case .copy: .copy
        case .move: .move
        case .alias: .link
        case .menu: .generic
        case .none: []
        }
    }

    static func isPromiseOnly(_ pasteboard: NSPasteboard) -> Bool {
        let types = Set(pasteboard.types ?? [])
        let promises = Set(NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        return !types.contains(.fileURL) && !types.contains(DragPasteboard.filenamesType) && !types.isDisjoint(with: promises)
    }

    private func sources(_ info: any NSDraggingInfo) -> [URL] {
        if cachedSequence != info.draggingSequenceNumber {
            cachedSequence = info.draggingSequenceNumber
            cachedURLs = DragPasteboard.readURLs(from: info.draggingPasteboard)
        }
        return cachedURLs
    }

    /// Drops from apps that use file promises (§5.6): the source app writes into `destination`.
    private func receivePromises(_ pasteboard: NSPasteboard, destination: URL) -> Bool {
        let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
        guard !receivers.isEmpty else { return false }
        let bus = context.environment.changeBus
        for receiver in receivers {
            receiver.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: Self.promiseQueue) { url, error in
                guard error == nil else { return }
                let name = url.lastPathComponent
                Task { @MainActor in bus.post([LocalChange(directory: destination, added: [name])]) }
            }
        }
        return true
    }
}

/// Glue for S4-owned destination views (breadcrumb segments): call from their NSDraggingDestination overrides.
@MainActor
final class FolderDropForwarder {
    let target: DropTarget
    let destination: @MainActor () -> URL?

    init(target: DropTarget, destination: @escaping @MainActor () -> URL?) {
        self.target = target
        self.destination = destination
    }

    func validate(_ info: any NSDraggingInfo) -> NSDragOperation {
        guard let url = destination() else { return [] }
        return target.validate(info, destination: url)
    }

    func perform(_ info: any NSDraggingInfo, in view: NSView) -> Bool {
        guard let url = destination() else { return false }
        return target.perform(info, destination: url, in: view)
    }
}
