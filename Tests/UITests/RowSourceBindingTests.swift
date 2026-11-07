import XCTest
import AppKit
@testable import UI
@testable import Core
@testable import MacxFS
import MacxFixtures

/// P3-09: Details and Icons draw any RowSource (folder or search results); Path column, results column set, results
/// empty states, results in the content area and inline rename of a result. Every file lives in this test's sandbox.
@MainActor
final class RowSourceBindingTests: XCTestCase {
    var sandbox: Sandbox!
    var context: UIContext!
    var env: CoreEnvironment { context.environment }

    override func setUp() async throws {
        sandbox = try Sandbox()
        let s = sandbox!
        addTeardownBlock { s.destroy() }
        let env = CoreEnvironment.sandboxed(root: sandbox.root)
        var options = LaunchOptions()
        options.root = sandbox.root
        options.stateDirectory = try sandbox.createDirectory("state")
        context = UIContext(environment: env, options: options)
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < end else { return XCTFail("timed out: \(what)") }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// What ContentViewController does in a window: the source's row events reach the list.
    private func forward(_ source: any RowSource, to list: FileListView) {
        let token = source.observeRows { [weak list] event in
            switch event {
            case .changes(let changes): list?.apply(changes)
            case .selection: list?.reloadSelectionDrawing()
            case .beginRename(let row): list?.beginInlineRename(row: row)
            }
        }
        addTeardownBlock { token.cancel() }
    }

    private func p(_ relative: String) -> String { sandbox.root.appending(path: relative).path(percentEncoded: false) }

    /// A results model fed from a fixed list of (parent, names); completes at once.
    private func results(_ items: [(String, [String])], query: String = "q") -> SearchResultsModel {
        let types = env.types
        let model = SearchResultsModel(title: query, events: { g in
            AsyncStream { c in
                for (parent, names) in items {
                    var b = Batch(generation: g)
                    for n in names {
                        let e = Entry(rowID: 1, fileID: 1, size: 3, allocSize: 3, mtime: 0, ctime: 0, nameOffset: 0,
                                      nameLen: UInt16(n.utf8.count), kind: .file, flags: [.readable],
                                      typeIndex: types.index(forExtension: Substring((n as NSString).pathExtension), isDirectory: false))
                        Array(n.utf8).withUnsafeBufferPointer { b.append(e, nameBytes: $0) }
                    }
                    c.yield(.batch(SearchBatch(parent: URL(filePath: parent, directoryHint: .isDirectory), batch: b)))
                }
                c.yield(.completed(SearchSummary(resultCount: items.reduce(0) { $0 + $1.1.count })))
                c.finish()
            }
        }, context: env.searchContext())
        addTeardownBlock { @MainActor in model.close() }
        return model
    }

    func testPathCellAbbreviatesHomeAndTruncatesInTheMiddle() {
        let cell = PathCellView()
        cell.configure(parent: URL(filePath: "/Users/someone/dev/project", directoryHint: .isDirectory),
                       home: URL(filePath: "/Users/someone", directoryHint: .isDirectory))
        XCTAssertEqual(cell.textField?.stringValue, "~/dev/project")
        XCTAssertEqual(cell.toolTip, "/Users/someone/dev/project")
        XCTAssertEqual(cell.accessibilityValue() as? String, "/Users/someone/dev/project")
        XCTAssertEqual(cell.textField?.lineBreakMode, .byTruncatingMiddle)
        cell.configure(parent: URL(filePath: "/Volumes/Data", directoryHint: .isDirectory), home: URL(filePath: "/Users/someone"))
        XCTAssertEqual(cell.textField?.stringValue, "/Volumes/Data")
    }

    func testDetailsShowsResultsWithPathColumn() async {
        let model = results([(p("b"), ["z.txt"]), (p("a"), ["y.txt", "x.txt"])])
        let details = DetailsViewController(context: context)
        _ = details.view
        details.bind(model)
        forward(model, to: details)
        model.start()
        await waitUntil("rows") { details.tableView.numberOfRows == 3 }
        let visible = details.tableView.tableColumns.filter { !$0.isHidden }.map(\.identifier.rawValue)
        XCTAssertEqual(visible, env.settings.resultsColumns.filter(\.visible).map { DetailsColumns.identifier($0.id).rawValue })
        XCTAssertTrue(visible.contains(DetailsColumns.identifier(.path).rawValue))
        let pathColumn = details.tableView.column(withIdentifier: DetailsColumns.identifier(.path))
        let cell = details.tableView(details.tableView, viewFor: details.tableView.tableColumns[pathColumn], row: 0) as? PathCellView
        XCTAssertEqual(cell?.toolTip, p("a"))
        XCTAssertTrue(details.source === model)
        XCTAssertNil(details.folder)
        // Extended (Phase 2) columns are not offered for results; Path is.
        let offered = details.headerMenu().items.compactMap { $0.representedObject as? String }
        XCTAssertTrue(offered.contains(ColumnID.path.rawValue))
        XCTAssertFalse(offered.contains(ColumnID.tags.rawValue))
    }

    func testFolderSourceKeepsFolderColumns() async throws {
        _ = try sandbox.createFile("f/a.txt")
        let folder = env.makeFolderModel(sandbox.url("f"))
        addTeardownBlock { @MainActor in folder.close() }
        let details = DetailsViewController(context: context)
        _ = details.view
        details.bind(folder)
        forward(folder, to: details)
        folder.start()
        await waitUntil("rows") { details.tableView.numberOfRows == 1 }
        let pathColumn = details.tableView.tableColumns.first { $0.identifier == DetailsColumns.identifier(.path) }
        XCTAssertTrue(pathColumn?.isHidden ?? true)
        XCTAssertTrue(details.folder === folder)
        XCTAssertTrue(details.source === folder)
    }

    func testResultsThenFolderRestoresFolderColumns() async throws {
        _ = try sandbox.createFile("f/a.txt")
        let folder = env.makeFolderModel(sandbox.url("f"))
        addTeardownBlock { @MainActor in folder.close() }
        let details = DetailsViewController(context: context)
        _ = details.view
        details.bind(folder)
        forward(folder, to: details)
        folder.start()
        await waitUntil("folder rows") { details.tableView.numberOfRows == 1 }
        let folderVisible = details.visibleColumnIDs()
        let model = results([(p("a"), ["one.txt", "two.txt"])])
        details.bind(model)
        forward(model, to: details)
        model.start()
        await waitUntil("result rows") { details.tableView.numberOfRows == 2 }
        XCTAssertTrue(details.visibleColumnIDs().contains(ColumnID.path.rawValue))
        // A view-state update for the folder while results are shown does not replace the results columns.
        details.apply(columns: Settings.defaultColumns, sort: .default)
        XCTAssertTrue(details.visibleColumnIDs().contains(ColumnID.path.rawValue))
        details.bind(folder)
        XCTAssertEqual(details.visibleColumnIDs(), folderVisible)
    }

    func testHeaderSortAndColumnWidthsPersistToResultsColumns() async {
        let model = results([(p("b"), ["a.txt"]), (p("a"), ["z.txt"])])
        let details = DetailsViewController(context: context)
        var folderColumnWrites = 0
        details.onColumnsChanged = { _ in folderColumnWrites += 1 }
        var folderSortWrites = 0
        details.onSortChanged = { _ in folderSortWrites += 1 }
        _ = details.view
        details.bind(model)
        forward(model, to: details)
        model.start()
        await waitUntil("rows") { details.tableView.numberOfRows == 2 }
        let folderColumns = env.settings.columns
        details.sort(by: .path)
        await waitUntil("path sort") { model.sortDescriptor.field == .path && model.name(atRow: 0) == "z.txt" }
        let column = details.tableView.tableColumns[details.tableView.column(withIdentifier: DetailsColumns.identifier(.path))]
        column.width = 333
        NotificationCenter.default.post(name: NSTableView.columnDidResizeNotification, object: details.tableView)
        XCTAssertEqual(env.settings.resultsColumns.first { $0.id == .path }?.width, 333)
        XCTAssertEqual(env.settings.columns, folderColumns)
        XCTAssertEqual(folderColumnWrites, 0, "results columns never reach the folder's view state")
        XCTAssertEqual(folderSortWrites, 0, "results sort never reaches the folder's view state")
    }

    func testIconsBindResults() async {
        let model = results([(p("a"), ["one.txt", "two.txt"])])
        let icons = IconsViewController(context: context)
        _ = icons.view
        icons.bind(model)
        forward(model, to: icons)
        model.start()
        await waitUntil("items") { icons.collectionView.numberOfItems(inSection: 0) == 2 }
        XCTAssertTrue(icons.source === model)
        XCTAssertNil(icons.folder)
    }

    func testResultsEmptyStates() {
        let searching = EmptyStateContent.make(search: .searching(SearchProgress()), notices: [], rowCount: 0, query: "tax")
        XCTAssertEqual(searching?.showsSpinner, true)
        XCTAssertEqual(searching?.title, L10n.string("search.empty.searching"))
        let none = EmptyStateContent.make(search: .complete(SearchSummary()), notices: [], rowCount: 0, query: "tax")
        XCTAssertEqual(none?.title, String(format: L10n.string("search.empty.noResults"), "tax"))
        XCTAssertNil(none?.action)
        let off = EmptyStateContent.make(search: .complete(SearchSummary()), notices: [.spotlightOff], rowCount: 0, query: "tax")
        XCTAssertEqual(off?.action, .searchSubfolders)
        let notIndexed = EmptyStateContent.make(search: .complete(SearchSummary()), notices: [.mayNotBeIndexed], rowCount: 0, query: "tax")
        XCTAssertEqual(notIndexed?.detail, L10n.string("search.empty.mayNotBeIndexed"))
        XCTAssertEqual(notIndexed?.action, .searchSubfolders)
        let stopped = EmptyStateContent.make(search: .stopped(SearchSummary()), notices: [], rowCount: 0, query: "tax")
        XCTAssertEqual(stopped?.title, L10n.string("search.empty.stopped"))
        XCTAssertEqual(stopped?.action, .searchAgain)
        let gone = EmptyStateContent.make(search: .failed(.rootUnreadable(.notFound)), notices: [], rowCount: 0, query: "tax")
        XCTAssertEqual(gone?.action, .searchAgain)
        XCTAssertEqual(gone?.title, String(format: L10n.string("search.empty.rootGone"), "tax"))
        let denied = EmptyStateContent.make(search: .failed(.rootUnreadable(.permissionPOSIX)), notices: [], rowCount: 0, query: "tax")
        XCTAssertEqual(denied?.title, String(format: L10n.string("search.empty.noPermission"), "tax"))
        let slow = EmptyStateContent.make(search: .failed(.volumeUnresponsive), notices: [], rowCount: 0, query: "tax")
        XCTAssertEqual(slow?.action, .searchAgain)
        let failed = EmptyStateContent.make(search: .failed(.spotlightFailed), notices: [], rowCount: 0, query: "tax")
        XCTAssertEqual(failed?.title, L10n.string("search.empty.spotlightFailed"))
        XCTAssertNil(EmptyStateContent.make(search: .complete(SearchSummary()), notices: [], rowCount: 3, query: "tax"))
        // Every key has an English text (not the key itself).
        for key in ["search.empty.searching", "search.empty.noResults", "search.empty.spotlightOff", "search.empty.spotlightOff.detail",
                    "search.empty.mayNotBeIndexed", "search.empty.stopped", "search.empty.rootGone", "search.empty.noPermission",
                    "search.empty.unresponsive", "search.empty.spotlightFailed"] {
            XCTAssertNotEqual(L10n.string(key), key, key)
        }
    }

    func testContentShowsResultsInDetailsEvenInColumnsMode() async {
        let session = BrowserSession(environment: env, initialURL: sandbox.root)
        addTeardownBlock { @MainActor in session.close() }
        let content = ContentViewController(context: context, session: session)
        _ = content.view
        content.setViewMode(.columns)
        let model = results([(p("a"), ["one.txt"])])
        content.display(model)
        model.start()
        XCTAssertTrue(content.activeList is DetailsViewController)
        XCTAssertEqual(content.focusContext, .searchResults)
        await waitUntil("rows") { content.activeList.source?.rowCount == 1 }
        await waitUntil("status") { content.statusBar.countText == StatusText.items(1) }
        XCTAssertEqual(content.statusBar.availableText, "", "free space is shown only for folders")
        content.display(session.folder)
        XCTAssertEqual(content.focusContext, .content)
        XCTAssertTrue(content.activeList.source === session.folder)
    }

    func testContentShowsResultsEmptyState() async {
        let session = BrowserSession(environment: env, initialURL: sandbox.root)
        addTeardownBlock { @MainActor in session.close() }
        let content = ContentViewController(context: context, session: session)
        _ = content.view
        let model = results([], query: "nothing-here")
        content.display(model)
        model.start()
        await waitUntil("no results") {
            content.emptyState.currentText == String(format: L10n.string("search.empty.noResults"), "nothing-here")
        }
    }

    func testInlineRenameOfAResultRenamesTheFileAndTheRow() async throws {
        try requireGUISession()
        _ = await env.start()                       // the job queue runs the rename
        _ = try sandbox.createFile("work/sub/old-name.txt")
        let spec = SearchSpec(text: "old-name", scope: .subfolders, root: sandbox.url("work"))
        let plan = await env.planSearch(spec)
        let model = env.makeSearchResults(spec, plan: plan)
        addTeardownBlock { @MainActor in model.close() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        addTeardownBlock { @MainActor in window.close() }
        let details = DetailsViewController(context: context)
        window.contentView = details.view
        details.bind(model)
        forward(model, to: details)
        model.start()
        await waitUntil("result") { model.rowCount == 1 }
        let rename = InlineRenameController(list: details, source: model, environment: env)
        rename.begin(row: 0)
        XCTAssertTrue(rename.isEditing)
        let editor = try XCTUnwrap(rename.field?.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("new-name.txt", replacementRange: editor.selectedRange())
        rename.commit(moveToNext: false)
        await waitUntil("renamed on disk") {
            FileManager.default.fileExists(atPath: self.sandbox.url("work/sub/new-name.txt").path(percentEncoded: false))
        }
        await waitUntil("row re-keyed") { model.rowCount == 1 && model.name(atRow: 0) == "new-name.txt" }
        XCTAssertEqual(model.url(atRow: 0).lastPathComponent, "new-name.txt")
        await waitUntil("re-selected") { model.selectedURLs.map(\.lastPathComponent) == ["new-name.txt"] }
    }
}
