import AppKit
import Core
import MacxFS

/// Runs every Command for every CommandTarget (§5.3, §5.4, §5.6, §5.7). The responder-chain @objc actions in
/// CommandHandlingViewController, the command bar, context menus and KeyRouter alternates all end here.
@MainActor
final class FileCommandController: CommandHandler {
    let context: UIContext
    private(set) weak var window: BrowserWindowController?
    var prompts: any CommandPrompts = AppKitCommandPrompts()
    /// Set by SidebarViewController so F2 on a Folders-tree node renames inline there; nil → a name prompt.
    var beginSidebarRename: ((URL) -> Void)?
    /// Commands whose UI arrives in a later task (P1-37 removes .properties, P1-38 removes .showOperations).
    static let pendingCommands: Set<Command> = [.properties, .showOperations]

    var environment: CoreEnvironment { context.environment }
    var session: BrowserSession? { window?.session }

    init(context: UIContext, window: BrowserWindowController) {
        self.context = context
        self.window = window
    }

    static func focus(for target: CommandTarget) -> FocusContext {
        switch target {
        case .contentSelection, .currentFolder: .content
        case .folder: .sidebarFolders
        case .favorite: .sidebarFavorites
        case .volume, .location: .sidebarLocations
        }
    }

    func canPerform(_ command: Command, target: CommandTarget) -> Bool {
        let focus = Self.focus(for: target)
        guard let effective = CommandAvailability.effectiveCommand(command, focus: focus),
              !Self.pendingCommands.contains(effective), let session else { return false }
        let state = CommandStateBuilder.state(for: target, session: session, environment: environment)
        return CommandAvailability.isEnabled(effective, focus: focus, state: state)
    }

    func perform(_ command: Command, target: CommandTarget, sender: Any?) {
        guard let effective = CommandAvailability.effectiveCommand(command, focus: Self.focus(for: target)),
              canPerform(command, target: target) else {
            NSSound.beep()
            return
        }
        defer { environment.clipboard.revalidate() }   // §5.6: after every command
        switch effective {
        case .open: open(target, newWindow: false)
        case .openInNewWindow: open(target, newWindow: true)
        case .showPackageContents: showPackageContents(target)
        case .openInTerminal: openInTerminal(target)
        case .revealInFinder: reveal(target)
        case .cut: environment.clipboard.cut(subjectURLs(target))
        case .copy: environment.clipboard.copy(subjectURLs(target))
        case .paste: paste(target, moveItemHere: false)
        case .moveItemHere: paste(target, moveItemHere: true)
        case .selectAll: select(.all, target)
        case .selectNone: select(.none, target)
        case .invertSelection: select(.invert, target)
        case .undo: environment.undo.undoManager.undo()
        case .redo: environment.undo.undoManager.redo()
        case .rename: rename(target)
        case .moveToTrash: trash(target)
        case .deletePermanently: deletePermanently(target)
        case .duplicate: enqueue(.duplicate(subjectURLs(target)))
        case .makeAlias: enqueue(.alias(sources: subjectURLs(target), destination: containingFolder(target)))
        case .makeSymlink: enqueue(.symlink(sources: subjectURLs(target), destination: containingFolder(target)))
        case .newFolder: enqueue(.newItem(.folder, in: destinationFolder(target)))
        case .newTextFile: enqueue(.newItem(.textFile, in: destinationFolder(target)))
        case .newEmptyFile: enqueue(.newItem(.emptyFile, in: destinationFolder(target)))
        case .copyAsPath: TextPasteboard.write(subjectURLs(target).map(\.path).joined(separator: "\n"), options: context.options)
        case .properties: showProperties(target)
        case .share: share(target, sender: sender)
        case .back, .forward, .up, .refresh, .focusAddressBar, .focusSearch, .cycleFocusForward, .cycleFocusBackward,
             .newWindow, .closeWindow, .showOperations:
            performWindowCommand(effective, target: target)
        case .viewAsDetails, .viewAsIcons, .iconSizeSmall, .iconSizeMedium, .iconSizeLarge, .densityCompact, .densityRegular,
             .densityComfortable, .toggleHidden, .toggleCommandBar, .sortByName, .sortByDateModified, .sortBySize, .sortByKind,
             .sortByDateCreated, .sortAscending, .sortDescending:
            performViewCommand(effective)
        case .eject: eject(target)
        case .removeFromFavorites: removeFavorite(target)
        case .cancelOperation: environment.clipboard.clearCut()
        }
    }

    // MARK: subjects and destinations

    /// The items a command acts on: the selection, the current folder, or the sidebar row's target.
    func subjectURLs(_ target: CommandTarget) -> [URL] {
        switch target {
        case .contentSelection(let folder): folder.selectedURLs
        case .currentFolder(let folder): [folder.directory]
        case .folder(let url), .location(let url): [url]
        case .favorite(let favorite): favorite.url.map { [$0] } ?? []
        case .volume(let volume): [volume.mountPoint]
        }
    }

    /// Where Paste and New go (§5.6): the current folder for content targets, whatever is selected.
    func destinationFolder(_ target: CommandTarget) -> URL {
        switch target {
        case .contentSelection(let folder), .currentFolder(let folder): folder.directory
        case .folder(let url), .location(let url): url
        case .favorite(let favorite): favorite.url ?? environment.settings.home
        case .volume(let volume): volume.mountPoint
        }
    }

    /// Where Make Alias / Create Symbolic Link put the new item: next to the subjects.
    func containingFolder(_ target: CommandTarget) -> URL {
        switch target {
        case .contentSelection(let folder), .currentFolder(let folder): folder.directory
        case .folder(let url): url.deletingLastPathComponent()
        case .favorite, .volume, .location: environment.settings.home
        }
    }

    func contentController() -> ContentViewController? {
        window?.contentViewController?.firstDescendant(of: ContentViewController.self)
    }

    @discardableResult
    func enqueue(_ kind: JobKind) -> Task<JobOutcome, Never> {
        let request = JobRequest(kind, origin: window?.origin)
        let operations = environment.operations
        return Task { await operations.perform(request) }
    }

    func run(_ kind: JobKind) async -> JobOutcome {
        await environment.operations.perform(JobRequest(kind, origin: window?.origin))
    }

    private func select(_ command: SelectionCommand, _ target: CommandTarget) {
        if case .contentSelection(let folder) = target { folder.select(command) }
    }

    /// Filled in by P1-37 (Properties window).
    func showProperties(_ target: CommandTarget) {
        NSSound.beep()
    }
}
