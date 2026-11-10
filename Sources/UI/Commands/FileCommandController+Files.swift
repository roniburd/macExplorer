import AppKit
import Core
import MacxFS

extension FileCommandController {
    // MARK: open (§5.7)

    func open(_ target: CommandTarget, newWindow: Bool) {
        switch target {
        case .resultsSelection(let results):
            let items = openItems(rows: Array(results.selection.rows), in: results)
            guard !items.isEmpty else { return }
            let lanes = environment.lanes
            let volumes = environment.volumes
            Task {
                await self.execute(await OpenPlanner.plan(items, newWindow: newWindow, lanes: lanes, volumes: volumes))
            }
        case .contentSelection(let folder):
            // Columns (P2-19): open on the single selected folder whose column is already open moves into it.
            if !newWindow, session?.columnChain?.enterSelectedFolder(of: folder) == true { return }
            let items = folder.selection.rows.filter { $0 < folder.rowCount }.map { row in
                let entry = folder.entry(atRow: row)
                return OpenItem(url: folder.url(atRow: row), kind: entry.kind, isApplication: environment.types.isApplication(entry.typeIndex))
            }
            guard !items.isEmpty else { return }
            // No listing fileID shortcut for the folder's view state (P2-08 review fix): for a mount point (and
            // possibly a firmlink) the listing reports the covered folder while every other route's stat probe
            // reports the mounted root, so the folder would get two keys. The session probes, as on every route.
            let lanes = environment.lanes
            let volumes = environment.volumes
            Task {
                await self.execute(await OpenPlanner.plan(items, newWindow: newWindow, lanes: lanes, volumes: volumes))
            }
        case .folder, .favorite, .volume, .location:
            guard let url = subjectURLs(target).first else { return }
            if newWindow { context.windows.openWindow(at: url) } else { window?.navigate(to: url) }
        case .savedSearch(let saved):
            openSavedSearch(saved, in: newWindow ? .newWindow : .thisWindow)
        case .currentFolder(let folder):
            if newWindow { context.windows.openWindow(at: folder.directory) }
        }
    }

    /// OpenPlanner items for `rows` of a folder or search results.
    func openItems(rows: [Int], in source: any RowSource) -> [OpenItem] {
        rows.filter { $0 >= 0 && $0 < source.rowCount }.map { row in
            let entry = source.entry(atRow: row)
            return OpenItem(url: source.url(atRow: row), kind: entry.kind, isApplication: environment.types.isApplication(entry.typeIndex))
        }
    }

    // MARK: open in new tab (P2-06)

    /// Open in New Tab (File menu, context menu, command bar): every selected folder or link to one, the first new tab
    /// selected; a sidebar row's folder, selected.
    func openInNewTab(_ target: CommandTarget) {
        switch target {
        case .contentSelection(let folder):
            openInNewTab(rows: folder.selection.rows.filter { MiddleClickRouter.folderTarget(row: $0, in: folder) != nil },
                         in: folder, select: true)
        case .resultsSelection(let results):
            openInNewTab(rows: results.selection.rows.filter { MiddleClickRouter.folderTarget(row: $0, in: results) != nil },
                         in: results, select: true)
        case .folder, .favorite, .volume, .location:
            window?.openTabs(subjectURLs(target), select: true)
        case .savedSearch(let saved):
            openSavedSearch(saved, in: .newTab)
        case .currentFolder(let folder):
            window?.openTabs([folder.directory], select: true)
        }
    }

    /// Content rows into tabs: OpenPlanner resolves links (newWindow: true, so folders come back as openInNewWindow),
    /// only folder targets open, a broken link shows the Phase 1 alert, and more than 10 folders ask first.
    /// `select: false` (middle-click) opens background tabs.
    func openInNewTab(rows: [Int], in folder: any RowSource, select: Bool) {
        let items = openItems(rows: rows, in: folder)
        guard !items.isEmpty else { return }
        let lanes = environment.lanes
        let volumes = environment.volumes
        Task {
            let plan = await OpenPlanner.plan(items, newWindow: true, lanes: lanes, volumes: volumes)
            await self.executeInTabs(plan, select: select)
        }
    }

    private func executeInTabs(_ plan: OpenPlan, select: Bool) async {
        var folders: [URL] = []
        var broken: [URL] = []
        for action in plan.actions {
            switch action {
            case .navigate(let url), .openInNewWindow(let url): folders.append(url)
            case .brokenLink(let url): broken.append(url)
            case .launchApplication, .openDocuments: break   // tabs show folders only
            }
        }
        if plan.needsConfirmation {
            guard await prompts.confirm(.openManyTabs(folders.count), window: window?.window) else { return }
        }
        window?.openTabs(folders, select: select)
        for url in broken { await handleBrokenLink(url) }
    }

    func execute(_ plan: OpenPlan) async {
        if plan.needsConfirmation {
            let windows = plan.actions.filter { if case .openInNewWindow = $0 { true } else { false } }.count
            guard await prompts.confirm(.openManyWindows(windows), window: window?.window) else { return }
        }
        for action in plan.actions {
            switch action {
            case .navigate(let url): window?.navigate(to: url)
            case .openInNewWindow(let url): context.windows.openWindow(at: url)
            case .launchApplication(let url): await openWithErrors([url], app: nil)
            case .openDocuments(let urls): await openWithErrors(urls, app: nil)
            case .brokenLink(let url): await handleBrokenLink(url)
            }
        }
    }

    func openWith(_ files: [URL], app: URL) {
        Task { await self.openWithErrors(files, app: app) }
    }

    func openWithOther(_ files: [URL]) {
        Task {
            guard let app = await self.prompts.chooseFile(directory: URL(filePath: "/Applications", directoryHint: .isDirectory),
                                                         applicationsOnly: true, window: self.window?.window) else { return }
            await self.openWithErrors(files, app: app)
        }
    }

    func chooseDefaultApp(for file: URL) {
        guard let hostWindow = window?.window else { return }
        let context = self.context
        Task { await DefaultAppSheet.present(for: file, on: hostWindow, context: context) }
    }

    /// Open With errors are an alert naming the app (§5.7).
    func openWithErrors(_ files: [URL], app: URL?) async {
        let provider = environment.launchServices.provider
        do {
            if let app { try await provider.open(files, withApplicationAt: app) } else { try await provider.open(files) }
        } catch {
            let appName = app.map { $0.deletingPathExtension().lastPathComponent }
            await prompts.inform(.openFailed(file: files.first?.lastPathComponent ?? "", app: appName,
                                             message: error.localizedDescription), window: window?.window)
        }
    }

    func handleBrokenLink(_ url: URL) async {
        switch await prompts.brokenLink(url.lastPathComponent, window: window?.window) {
        case .cancel:
            return
        case .delete:
            _ = await run(.trash([url]))
        case .fix:
            guard let newTarget = await prompts.chooseFile(directory: nil, applicationsOnly: false, window: window?.window) else { return }
            let parent = url.deletingLastPathComponent()
            let folder = session?.folder
            let isSymlink = folder?.row(named: url.lastPathComponent).map { folder?.entry(atRow: $0).kind == .symlink } ?? true
            guard await run(.trash([url])).skipped.isEmpty else { return }
            let made = await run(isSymlink ? .symlink(sources: [newTarget], destination: parent) : .alias(sources: [newTarget], destination: parent))
            if let created = made.created.first, created.lastPathComponent != url.lastPathComponent {
                _ = await run(.rename(created, to: url.lastPathComponent))
            }
        }
    }

    func showPackageContents(_ target: CommandTarget) {
        guard let folder = Self.listSource(target), let row = folder.selection.rows.first, row < folder.rowCount,
              folder.entry(atRow: row).kind == .package else { return }
        window?.navigate(to: folder.url(atRow: row))
    }

    func openInTerminal(_ target: CommandTarget) {
        let folderURL: URL
        if let folder = Self.listSource(target), folder.selection.rows.count == 1, let row = folder.selection.rows.first,
           row < folder.rowCount, folder.entry(atRow: row).kind == .directory {
            folderURL = folder.url(atRow: row)
        } else {
            folderURL = destinationFolder(target)
        }
        let terminal = environment.settings.terminalApp
            ?? URL(filePath: "/System/Applications/Utilities/Terminal.app", directoryHint: .isDirectory)
        openWith([folderURL], app: terminal)
    }

    func reveal(_ target: CommandTarget) {
        var urls = subjectURLs(target)
        if urls.isEmpty, case .contentSelection(let folder) = target { urls = [folder.directory] }
        let provider = environment.launchServices.provider
        Task { await provider.revealInFinder(urls) }
    }

    // MARK: clipboard (§5.6)

    func paste(_ target: CommandTarget, moveItemHere: Bool) {
        let clipboard = environment.clipboard
        guard let plan = clipboard.pastePlan(into: destinationFolder(target), moveItemHere: moveItemHere) else {
            NSSound.beep()
            return
        }
        if plan.isNoOp {
            clipboard.didPaste(plan)   // cut-paste into the items' own folder: nothing moves, the cut state clears
            return
        }
        let kind: JobKind = plan.operation == .move
            ? .move(sources: plan.sources, destination: plan.destination)
            : .copy(sources: plan.sources, destination: plan.destination)
        let job = enqueue(kind)
        Task {
            _ = await job.value
            clipboard.didPaste(plan)
        }
    }

    // MARK: rename, trash, delete

    func rename(_ target: CommandTarget) {
        switch target {
        case .contentSelection(let folder) where folder.selection.rows.count > 1:
            batchRename(target)
        case .resultsSelection(let results) where results.selection.rows.count > 1:
            batchRename(target)
        case .contentSelection(let folder):
            guard let row = folder.selection.cursor.flatMap({ folder.row(of: $0) }) ?? folder.selection.rows.first,
                  let content = contentController() else { return }
            content.activeList.beginInlineRename(row: row)
        case .resultsSelection(let results):
            guard let row = results.selection.cursor.flatMap({ results.row(of: $0) }) ?? results.selection.rows.first,
                  let content = contentController(), content.activeList.source === results else { return }
            content.activeList.beginInlineRename(row: row)
        case .folder(let url):
            if let beginSidebarRename { beginSidebarRename(url); return }
            Task { await self.renameWithPrompt(url) }
        default:
            break
        }
    }

    private func renameWithPrompt(_ url: URL) async {
        let current = url.lastPathComponent
        guard let proposed = await prompts.askName(current: current, window: window?.window), proposed != current else { return }
        let caseSensitive = environment.volumes.volume(for: url)?.capabilities.caseSensitive ?? false
        // Duplicates are caught by the rename primitive's RENAME_EXCL (conflict dialog); the tree has no EntryStore here.
        guard case .ok = NameRules.validate(proposed, original: current, caseSensitive: caseSensitive, exists: { _ in false }) else {
            NSSound.beep()
            return
        }
        _ = await run(.rename(url, to: proposed))
    }

    func trash(_ target: CommandTarget) {
        let urls = subjectURLs(target)
        guard !urls.isEmpty else { return }
        Task {
            if self.environment.settings.confirmBeforeTrash {
                guard await self.prompts.confirm(.confirmTrash(urls.count), window: self.window?.window) else { return }
            }
            _ = await self.run(.trash(urls))
        }
    }

    func deletePermanently(_ target: CommandTarget) {
        let urls = subjectURLs(target)
        guard !urls.isEmpty else { return }
        Task {
            // Always confirms (§6.3); Settings.confirmBeforeDelete is locked on.
            guard await self.prompts.confirm(.confirmDelete(urls.count), window: self.window?.window) else { return }
            _ = await self.run(.delete(urls))
        }
    }

    // MARK: share, eject, favorites

    func share(_ target: CommandTarget, sender: Any?) {
        let urls = subjectURLs(target)
        guard !urls.isEmpty else { return }
        let picker = NSSharingServicePicker(items: urls)
        if let view = sender as? NSView {
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        } else if let content = contentController() {
            picker.show(relativeTo: content.listContainer.bounds, of: content.listContainer, preferredEdge: .minY)
        }
    }

    /// The sidebar's EjectFlow (P1-28): asks about running operations, then ejects; failures name the processes.
    func eject(_ target: CommandTarget) {
        guard case .volume(let volume) = target else { return }
        let flow = EjectFlow(environment: environment, prompts: context.ejectPrompts)
        let host = window?.window
        Task { await flow.eject(volume, window: host) }
    }

    func removeFavorite(_ target: CommandTarget) {
        guard case .favorite(let resolved) = target else { return }
        SidebarFavoritesModel.remove(id: resolved.favorite.id, from: environment.settings)
    }
}
