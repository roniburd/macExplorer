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
    /// Commands whose UI arrives in a later Phase 2 task (disabled, never performed). The NSWindow tab commands are
    /// here too: NSWindow and BrowserWindowController handle them, so they never reach a pane's handler.
    /// Window tab commands (NSWindow handles them) and the Phase 3 commands whose actions land in later tasks:
    /// search and Open Containing Folder (P3-10), saved searches (P3-11), preview pane (P3-12). Disabled until then.
    static let pendingCommands: Set<Command> = Command.windowTabCommands.union(phase3Pending)
    static let phase3Pending: Set<Command> = [
        .openContainingFolder, .saveSearch, .stopSearch, .searchScopeThisFolder, .searchScopeSubfolders, .searchScopeThisMac,
        .searchModeName, .searchModeContents,                       // P3-10
        .renameSavedSearch, .removeSavedSearch,                     // P3-11
        .togglePreviewPane, .downloadForPreview,                    // P3-12
    ]

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
        var state = CommandStateBuilder.state(for: target, session: session, environment: environment,
                                              needsFolderCount: effective == .openInNewTab)
        if effective == .quickLook { state.quickLookVisible = window?.quickLook.isVisible ?? false }
        return CommandAvailability.isEnabled(effective, focus: focus, state: state,
                                             collidesWithTextEditing: ActiveKeyBindings.current.collidesWithTextEditing)
    }

    func perform(_ command: Command, target: CommandTarget, sender: Any?) {
        guard let effective = CommandAvailability.effectiveCommand(command, focus: Self.focus(for: target)),
              canPerform(command, target: target) else {
            // Space with nothing selected and no panel open does nothing (spec §11), like Finder.
            if CommandAvailability.effectiveCommand(command, focus: Self.focus(for: target)) != .quickLook { NSSound.beep() }
            return
        }
        defer { environment.clipboard.revalidate() }   // §5.6: after every command
        switch effective {
        case .open: open(target, newWindow: false)
        case .openInNewWindow: open(target, newWindow: true)
        case .openInNewTab: openInNewTab(target)
        case .showPackageContents: showPackageContents(target)
        case .openInTerminal: openInTerminal(target)
        case .revealInFinder: reveal(target)
        case .cut: environment.clipboard.cut(subjectURLs(target))
        case .copy: environment.clipboard.copy(subjectURLs(target))
        case .paste: paste(target, moveItemHere: false)
        case .moveItemHere: paste(target, moveItemHere: true)
        case .selectAll: select(.allVisible(excluding: hiddenModelRows(target)), target)
        case .selectNone: select(.none, target)
        case .invertSelection: select(.invertVisible(excluding: hiddenModelRows(target)), target)
        case .undo: UndoTarget.manager(window: window?.window, fallback: environment.undo.undoManager).undo()
        case .redo: UndoTarget.manager(window: window?.window, fallback: environment.undo.undoManager).redo()
        case .rename: rename(target)
        case .moveToTrash: trash(target)
        case .deletePermanently: deletePermanently(target)
        case .duplicate: enqueue(.duplicate(subjectURLs(target)))
        case .makeAlias: enqueue(.alias(sources: subjectURLs(target), destination: containingFolder(target)))
        case .makeSymlink: enqueue(.symlink(sources: subjectURLs(target), destination: containingFolder(target)))
        case .newFolder: enqueue(.newItem(.folder, in: destinationFolder(target)))
        case .newTextFile: enqueue(.newItem(.textFile, in: destinationFolder(target)))
        case .newEmptyFile: enqueue(.newItem(.emptyFile, in: destinationFolder(target)))
        case .copyAsPath, .copyPathTilde, .copyPathFileURL, .copyName, .copyPathShellQuoted:
            if let style = Self.pathStyle(for: effective) { copyPaths(style, target: target) }
        case .properties: showProperties(target)
        case .share: share(target, sender: sender)
        case .back, .forward, .up, .refresh, .focusAddressBar, .focusSearch, .cycleFocusForward, .cycleFocusBackward,
             .newWindow, .closeWindow, .showOperations:
            performWindowCommand(effective, target: target)
        case .viewAsDetails, .viewAsIcons, .viewAsColumns, .iconSizeSmall, .iconSizeMedium, .iconSizeLarge, .densityCompact, .densityRegular,
             .densityComfortable, .toggleHidden, .toggleCommandBar, .sortByName, .sortByDateModified, .sortBySize, .sortByKind,
             .sortByDateCreated, .sortAscending, .sortDescending, .useViewAsDefault, .resetFolderView:
            performViewCommand(effective)
        case .groupByNone, .groupByKind, .groupByDateModified, .groupBySize, .groupByName:
            if let groupBy = MenuValidation.groupBy(for: effective) { session?.updateViewState { $0.groupBy = groupBy } }
        case .applyViewToAllFolders: applyViewToAllFolders()
        case .toggleFolderSizes: toggleFolderSizes()
        case .eject: eject(target)
        case .removeFromFavorites: removeFavorite(target)
        case .cancelOperation:
            // Esc closes Quick Look first (Finder parity); otherwise it clears a pending cut.
            if window?.quickLook.hideIfVisible() != true { environment.clipboard.clearCut() }
        case .quickLook: window?.quickLook.toggle()
        case .newTab, .nextTab, .previousTab, .showTabBar, .showAllTabs, .moveTabToNewWindow, .mergeAllWindows,
             // P3-10 / P3-11 / P3-12
             .togglePreviewPane, .openContainingFolder, .saveSearch, .stopSearch,
             .searchScopeThisFolder, .searchScopeSubfolders, .searchScopeThisMac, .searchModeName, .searchModeContents,
             .renameSavedSearch, .removeSavedSearch, .downloadForPreview:
            break   // pendingCommands: canPerform is false, so perform beeps above
        }
    }

    /// View ▸ Calculate Folder Sizes (P2-14): per folder, saved in its view state; the session starts or stops sizing.
    func toggleFolderSizes() {
        session?.updateViewState { $0.calculateFolderSizes.toggle() }
    }

    // MARK: copy path (P2-04)

    /// Copy as Path is `.posix`; the four Copy Path As ▸ variants map one to one.
    static func pathStyle(for command: Command) -> PathStyle? {
        switch command {
        case .copyAsPath: .posix
        case .copyPathTilde: .tilde
        case .copyPathFileURL: .fileURL
        case .copyName: .name
        case .copyPathShellQuoted: .shellQuoted
        default: nil
        }
    }

    /// Plain text only (no file URLs, so a later ⌘V pastes no files), through the clipboard's backend: the private
    /// --pasteboard or, in a sandboxed run without one, memory (never NSPasteboard.general). A stale favorite gives no
    /// items, so nothing is copied. `perform` revalidates the clipboard afterwards, which drops a replaced cut.
    private func copyPaths(_ style: PathStyle, target: CommandTarget) {
        let items = Self.pathItems(for: target)
        guard !items.isEmpty else { return }
        environment.clipboard.backend.writeString(PathFormatter.format(items, style: style, home: environment.settings.home))
    }

    /// The selection in display order, or the target folder itself. Selected rows use their raw names (not
    /// url(atRow:), whose path text Foundation decomposes) so an NFC name is copied as NFC.
    static func pathItems(for target: CommandTarget) -> [PathItem] {
        switch target {
        case .contentSelection(let folder):
            folder.selection.rows.filter { $0 < folder.rowCount }.map { row in
                let kind = folder.entry(atRow: row).kind
                return PathItem(directory: folder.directory, name: folder.name(atRow: row),
                                isDirectory: kind == .directory || kind == .package)
            }
        case .currentFolder(let folder): [PathItem(url: folder.directory, isDirectory: true)]
        case .folder(let url), .location(let url): [PathItem(url: url, isDirectory: true)]
        case .favorite(let favorite): favorite.url.map { [PathItem(url: $0, isDirectory: true)] } ?? []
        case .volume(let volume): [PathItem(url: volume.mountPoint, isDirectory: true)]
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

    /// Rows the content list shows for `target`'s folder but hides (collapsed groups, QA round 2).
    private func hiddenModelRows(_ target: CommandTarget) -> IndexSet {
        guard case .contentSelection(let folder) = target, let list = contentController()?.activeList,
              list.folder === folder else { return [] }
        return list.hiddenModelRows
    }

    private func select(_ command: SelectionCommand, _ target: CommandTarget) {
        if case .contentSelection(let folder) = target { folder.select(command) }
    }

    /// ⌘I / ⌥Return / command bar / context menus / the empty state's Properties button (§5.8).
    func showProperties(_ target: CommandTarget) {
        switch Self.propertiesSubject(for: target, volumes: environment.volumes.list) {
        case .items(let urls)?: PropertiesWindowController.show(for: urls, context: context)
        case .volume(let volume)?: PropertiesWindowController.show(volume: volume, context: context)
        case nil: NSSound.beep()
        }
    }

    /// The selection (or, with nothing selected, the current folder); sidebar rows give their folder or volume.
    /// A single item that is a volume's mount point shows volume properties.
    static func propertiesSubject(for target: CommandTarget, volumes: [VolumeInfo]) -> PropertiesSubject? {
        let urls: [URL]
        switch target {
        case .volume(let volume): return .volume(volume)
        case .contentSelection(let folder): urls = folder.selectedURLs.isEmpty ? [folder.directory] : folder.selectedURLs
        case .currentFolder(let folder): urls = [folder.directory]
        case .folder(let url), .location(let url): urls = [url]
        case .favorite(let favorite):
            guard let url = favorite.url else { return nil }
            urls = [url]
        }
        if urls.count == 1, let volume = volumes.first(where: { $0.mountPoint.standardizedFileURL.path == urls[0].standardizedFileURL.path }) {
            return .volume(volume)
        }
        return .items(urls)
    }
}
