import XCTest
import AppKit
@testable import UI
@testable import Core
import MacxFS

/// P4-05: tag cache, Tags ▸ submenu, tag editor (popover and Properties) and the Tags column's dots.
/// Every file lives in the harness's sandbox; nothing touches Spotlight or the system pasteboard.
@MainActor final class TagUITests: XCTestCase {
    private func write(_ tags: [FileTag], _ url: URL, _ ui: ContentTestHarness) async throws {
        try await ui.context.environment.lanes.perform(on: .unknown) { _ in try TagIO.write(tags, to: url) }
    }

    private func read(_ url: URL, _ ui: ContentTestHarness) async throws -> [FileTag] {
        try await ui.context.environment.lanes.perform(on: .unknown) { _ in try TagIO.read(url) }
    }

    func testTagCachePrefetchesOnLaneAndNotifiesOnce() async throws {
        let ui = try await ContentTestHarness.make(self)
        let a = try ui.file("a.txt"), b = try ui.file("b.txt")
        try await write([FileTag(name: "Red", color: .red)], a, ui)
        let cache = ui.context.environment.tagCache
        var notified: [[URL]] = []
        let token = cache.observe { notified.append($0) }
        defer { token.cancel() }
        XCTAssertNil(cache.cachedTags(for: a))
        cache.prefetch([a, b, a])
        cache.prefetch([b])                                        // already pending: no second read
        try await ui.waitUntil("cache filled") { cache.cachedTags(for: b) != nil }
        XCTAssertEqual(cache.cachedTags(for: a), [FileTag(name: "Red", color: .red)])
        XCTAssertEqual(cache.cachedTags(for: b), [])
        XCTAssertEqual(notified.count, 1)
        XCTAssertEqual(Set(notified[0]), [a, b])
        cache.prefetch([a, b])                                     // already cached: nothing to do
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(notified.count, 1)
    }

    func testTagCacheTreatsReadErrorAsNoTagsAndInvalidateRereads() async throws {
        let ui = try await ContentTestHarness.make(self)
        let a = try ui.file("a.txt")
        let missing = ui.url("missing.txt")
        let cache = ui.context.environment.tagCache
        cache.prefetch([a, missing])
        try await ui.waitUntil("cache filled") { cache.cachedTags(for: missing) != nil && cache.cachedTags(for: a) != nil }
        XCTAssertEqual(cache.cachedTags(for: missing), [])
        try await write([FileTag(name: "Blue", color: .blue)], a, ui)
        XCTAssertEqual(cache.cachedTags(for: a), [], "stale until invalidated")
        cache.invalidate(a)
        XCTAssertNil(cache.cachedTags(for: a))
        try await ui.waitUntil("re-read") { cache.cachedTags(for: a) == [FileTag(name: "Blue", color: .blue)] }
    }

    func testTagCacheIsBounded() {
        var order = TagCache.Storage(capacity: 3)
        for name in ["a", "b", "c", "d"] { order.store("/\(name)", [FileTag(name: name)]) }
        XCTAssertNil(order.value("/a"), "the oldest insertion goes first")
        XCTAssertEqual(order.value("/d"), [FileTag(name: "d")])
        order.store("/b", [])                                      // an update keeps its place
        order.store("/e", [])
        XCTAssertNil(order.value("/b"))
        XCTAssertEqual(order.count, 3)
    }

    /// Removing and re-storing a key below capacity must not grow the order list without bound.
    func testTagCacheOrderStaysBoundedUnderRemoveAndStore() {
        var storage = TagCache.Storage(capacity: 100)
        for i in 0..<10 { storage.store("/keep\(i)", []) }
        for _ in 0..<10_000 {
            storage.remove("/busy")
            storage.store("/busy", [FileTag(name: "Log")])
        }
        XCTAssertEqual(storage.count, 11)
        XCTAssertLessThanOrEqual(storage.orderSlots, 2 * storage.count + 64)
        XCTAssertEqual(storage.value("/busy"), [FileTag(name: "Log")])
        for i in 0..<10 { XCTAssertEqual(storage.value("/keep\(i)"), []) }
        for i in 0..<100 { storage.store("/new\(i)", []) }       // eviction still goes oldest-first
        XCTAssertNil(storage.value("/keep0"))
        XCTAssertEqual(storage.count, 100)
    }

    func testTagMenuStatesComeFromCache() async throws {
        let ui = try await ContentTestHarness.make(self)
        let a = try ui.file("a.txt"), b = try ui.file("b.txt")
        try await write([FileTag(name: "Red", color: .red), FileTag(name: "Orange", color: .orange)], a, ui)
        try await write([FileTag(name: "Orange", color: .orange)], b, ui)
        let cache = ui.context.environment.tagCache
        cache.prefetch([a, b])
        try await ui.waitUntil("cache filled") { cache.cachedTags(for: b) != nil && cache.cachedTags(for: a) != nil }
        var performed: [TagEdit] = []
        let menu = TagMenu.build(for: [a, b], cache: cache, settings: ui.context.environment.settings) { performed.append($0) }
        XCTAssertEqual(menu.items.prefix(7).map(\.title), ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"])
        XCTAssertEqual(menu.items[0].state, .mixed)
        XCTAssertEqual(menu.items[1].state, .on)
        XCTAssertEqual(menu.items[2].state, .off)
        XCTAssertNotNil(menu.items[0].image, "a coloured dot")
        XCTAssertTrue(menu.items[7].isSeparatorItem)
        XCTAssertEqual(menu.items.last?.title, L10n.string("Edit Tags…"))
        XCTAssertEqual(menu.items.last?.action, Selector(Command.editTags.selectorName))
        menu.performActionForItem(at: 0)
        XCTAssertEqual(performed, [.toggle(FileTag(name: "Red", color: .red))])
    }

    func testTagMenuUnknownEntriesAreOffAndUpdateInPlace() async throws {
        let ui = try await ContentTestHarness.make(self)
        let a = try ui.file("a.txt")
        try await write([FileTag(name: "Green", color: .green)], a, ui)
        let cache = ui.context.environment.tagCache
        let menu = TagMenu.build(for: [a], cache: cache, settings: ui.context.environment.settings) { _ in }
        let green = try XCTUnwrap(menu.items.first { $0.title == "Green" })
        XCTAssertEqual(green.state, .off, "not cached yet: off, and prefetched")
        menu.delegate?.menuWillOpen?(menu)
        try await ui.waitUntil("state updated while open") { green.state == .on }
        menu.delegate?.menuDidClose?(menu)
    }

    func testCacheFollowsFinishedTagJobs() async throws {
        let ui = try await ContentTestHarness.make(self)
        let a = try ui.file("a.txt")
        let cache = ui.context.environment.tagCache
        cache.prefetch([a])
        try await ui.waitUntil("cached") { cache.cachedTags(for: a) == [] }
        _ = await ui.context.environment.operations.perform(JobRequest(.setTags([a], .add(FileTag(name: "Work"))), origin: nil))
        try await ui.waitUntil("cache invalidated by the finished job") { cache.cachedTags(for: a) == [FileTag(name: "Work")] }
    }

    /// Tags written behind the app's back (another app, Finder) reach the cache through the folder's watcher, and
    /// the Tags submenu follows.
    func testCacheFollowsTagsChangedOutsideTheApp() async throws {
        let ui = try await ContentTestHarness.make(self)
        let a = try ui.file("a.txt")
        _ = try await ui.openBrowserWindow()
        let cache = ui.context.environment.tagCache
        cache.prefetch([a])
        try await ui.waitUntil("cached") { cache.cachedTags(for: a) == [] }
        try await write([FileTag(name: "Red", color: .red)], a, ui)          // not a job: only the watcher sees it
        try await ui.waitUntil("cache follows the watcher") { cache.cachedTags(for: a) == [FileTag(name: "Red", color: .red)] }
        let menu = TagMenu.build(for: [a], cache: cache, settings: ui.context.environment.settings) { _ in }
        XCTAssertEqual(menu.items.first { $0.title == "Red" }?.state, .on)
    }

    /// A path reused after renames (a→b, then c→a) never shows the old item's tags.
    func testCacheFollowsRenamesThatReusePaths() async throws {
        let ui = try await ContentTestHarness.make(self)
        let a = try ui.file("a.txt"), c = try ui.file("c.txt")
        try await write([FileTag(name: "Red", color: .red)], a, ui)
        let cache = ui.context.environment.tagCache
        cache.prefetch([a, c])
        try await ui.waitUntil("cached") { cache.cachedTags(for: a) == [FileTag(name: "Red", color: .red)] && cache.cachedTags(for: c) != nil }
        let operations = ui.context.environment.operations
        _ = await operations.perform(JobRequest(.rename(a, to: "b.txt"), origin: nil))
        _ = await operations.perform(JobRequest(.rename(c, to: "a.txt"), origin: nil))
        try await ui.waitUntil("reused path re-read") { cache.cachedTags(for: a) == [] }
        XCTAssertEqual(cache.cachedTags(for: c) ?? [], [], "c.txt is gone")
    }

    func testCacheInvalidationIgnoresUncachedAndDropsChildren() async throws {
        let ui = try await ContentTestHarness.make(self)
        let a = try ui.file("d/a.txt"), b = try ui.file("d/sub/b.txt"), other = try ui.file("e.txt")
        let cache = ui.context.environment.tagCache
        cache.invalidateCached([a])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(cache.cachedTags(for: a), "not cached: nothing to read again")
        cache.prefetch([a, b, other])
        try await ui.waitUntil("cached") { [a, b, other].allSatisfy { cache.cachedTags(for: $0) != nil } }
        try await write([FileTag(name: "Blue", color: .blue)], a, ui)
        try await write([FileTag(name: "Blue", color: .blue)], b, ui)
        try await write([FileTag(name: "Blue", color: .blue)], other, ui)
        cache.invalidateChildren(of: ui.url("d"))
        try await ui.waitUntil("children re-read") { cache.cachedTags(for: a) == [FileTag(name: "Blue", color: .blue)] }
        XCTAssertEqual(cache.cachedTags(for: b), [], "only direct children")
        XCTAssertEqual(cache.cachedTags(for: other), [])
        cache.invalidateSubtrees([ui.url("d")])
        try await ui.waitUntil("subtree re-read") { cache.cachedTags(for: b) == [FileTag(name: "Blue", color: .blue)] }
        XCTAssertEqual(cache.cachedTags(for: other), [])
    }

    func testChoosingTagRunsJobUpdatesCacheAndUndoes() async throws {
        let ui = try await ContentTestHarness.make(self)
        let a = try ui.file("a.txt")
        let window = try await ui.openBrowserWindow()
        window.session.folder.select(.names(["a.txt"]))
        let controller = FileCommandController(context: ui.context, window: window)
        await controller.applyTagEdit(.toggle(FileTag(name: "Green", color: .green)), to: [a])
        let cache = ui.context.environment.tagCache
        try await ui.waitUntil("cache updated") { cache.cachedTags(for: a) == [FileTag(name: "Green", color: .green)] }
        XCTAssertEqual(ui.context.environment.settings.knownTags.first?.name, "Green")
        XCTAssertTrue(ui.context.environment.undo.canUndo)
        ui.context.environment.undo.undoManager.undo()
        try await ui.waitUntil("undo cleared tags") { cache.cachedTags(for: a) == [] }
        let onDisk = try await read(a, ui)
        XCTAssertEqual(onDisk, [])
    }

    func testEditorModelAddsNewTagAndRemovesTokenForMixedSelection() async throws {
        let ui = try await ContentTestHarness.make(self)
        let a = try ui.file("a.txt"), b = try ui.file("b.txt")
        try await write([FileTag(name: "Red", color: .red), FileTag(name: "Work")], a, ui)
        try await write([FileTag(name: "Work")], b, ui)
        let model = TagEditorModel(urls: [a, b], context: ui.context)
        try await ui.waitUntil("model loaded") { !model.tokens.isEmpty }
        XCTAssertEqual(model.tokens.map(\.name), ["Red", "Work"])
        XCTAssertEqual(model.mixed, ["Red"])
        model.tokens.removeAll { $0.name == "Work" }
        model.tokens.append(FileTag(name: "Project"))
        await model.commit()
        let ta = try await read(a, ui), tb = try await read(b, ui)
        XCTAssertEqual(ta.map(\.name), ["Red", "Project"], "the mixed Red stays on a only")
        XCTAssertEqual(tb.map(\.name), ["Project"])
        XCTAssertTrue(ui.context.environment.settings.knownTags.contains(FileTag(name: "Project")))
        XCTAssertEqual(model.mixed, ["Red"], "reloaded after the commit")
    }

    func testEditorModelColourChangeAndEachEditIsItsOwnUndo() async throws {
        let ui = try await ContentTestHarness.make(self)
        let a = try ui.file("a.txt")
        try await write([FileTag(name: "Work"), FileTag(name: "Home")], a, ui)
        let model = TagEditorModel(urls: [a], context: ui.context)
        try await ui.waitUntil("model loaded") { model.tokens.count == 2 }
        model.setColor(.blue, forTokenNamed: "work")
        model.tokens.append(FileTag(name: "New", color: .none))
        await model.commit()
        let after = try await read(a, ui)
        XCTAssertEqual(after, [FileTag(name: "Work", color: .blue), FileTag(name: "Home"), FileTag(name: "New")])
        let undo = ui.context.environment.undo.undoManager
        undo.undo()
        try await ui.waitUntil("first undo") { (try? TagIOTestRead.sync(a)) == [FileTag(name: "Work", color: .blue), FileTag(name: "Home")] }
        undo.undo()
        try await ui.waitUntil("second undo") { (try? TagIOTestRead.sync(a)) == [FileTag(name: "Work"), FileTag(name: "Home")] }
    }

    /// Recolouring is one job over all items, applied to each item's tags on disk at commit time: tags added
    /// elsewhere since the editor opened survive, and one undo restores every item.
    func testEditorRecolourKeepsNewerTagsAndIsOneUndo() async throws {
        let ui = try await ContentTestHarness.make(self)
        let a = try ui.file("a.txt"), b = try ui.file("b.txt")
        try await write([FileTag(name: "Work")], a, ui)
        try await write([FileTag(name: "Work")], b, ui)
        let model = TagEditorModel(urls: [a, b], context: ui.context)
        var performed: [JobKind] = []
        let operations = ui.context.environment.operations
        model.perform = { kind in performed.append(kind); return await operations.perform(JobRequest(kind, origin: nil)) }
        try await ui.waitUntil("model loaded") { model.isLoaded }
        try await write([FileTag(name: "Work"), FileTag(name: "Home", color: .red)], a, ui)    // after the editor read it
        model.setColor(.blue, forTokenNamed: "Work")
        await model.commit()
        XCTAssertEqual(performed, [.setTags([a, b], .recolor(FileTag(name: "Work", color: .blue)))])
        let ta = try await read(a, ui), tb = try await read(b, ui)
        XCTAssertEqual(ta, [FileTag(name: "Work", color: .blue), FileTag(name: "Home", color: .red)])
        XCTAssertEqual(tb, [FileTag(name: "Work", color: .blue)])
        ui.context.environment.undo.undoManager.undo()
        try await ui.waitUntil("one undo restores both") {
            (try? TagIOTestRead.sync(a)) == [FileTag(name: "Work"), FileTag(name: "Home", color: .red)]
                && (try? TagIOTestRead.sync(b)) == [FileTag(name: "Work")]
        }
    }

    /// An edit made while an earlier commit's job is still running reaches disk: the first commit's reload must not
    /// overwrite it, and the queued pass diffs it against what the first commit applied.
    func testEditDuringRunningCommitIsNotLost() async throws {
        let ui = try await ContentTestHarness.make(self)
        let a = try ui.file("a.txt")
        try await write([FileTag(name: "Work"), FileTag(name: "Home")], a, ui)
        let model = TagEditorModel(urls: [a], context: ui.context)
        try await ui.waitUntil("model loaded") { model.tokens.count == 2 }
        let operations = ui.context.environment.operations
        var gate: CheckedContinuation<Void, Never>?
        var calls = 0
        model.perform = { kind in
            calls += 1
            if calls == 1 { await withCheckedContinuation { gate = $0 } }
            return await operations.perform(JobRequest(kind, origin: nil))
        }
        model.setColor(.blue, forTokenNamed: "Work")
        let first = Task { await model.commit() }
        try await ui.waitUntil("first job started") { gate != nil }
        model.tokens.removeAll { $0.name == "Home" }
        let second = Task { await model.commit() }
        await second.value                      // queued behind the first: returns at once
        gate?.resume()
        await first.value
        let onDisk = try await read(a, ui)
        XCTAssertEqual(onDisk, [FileTag(name: "Work", color: .blue)])
        XCTAssertEqual(model.tokens, [FileTag(name: "Work", color: .blue)])
    }

    /// A reload (another job on the item finished) keeps edits the user hasn't committed yet.
    func testReloadKeepsUncommittedEdits() async throws {
        let ui = try await ContentTestHarness.make(self)
        let a = try ui.file("a.txt")
        try await write([FileTag(name: "Work"), FileTag(name: "Home")], a, ui)
        let model = TagEditorModel(urls: [a], context: ui.context)
        try await ui.waitUntil("model loaded") { model.tokens.count == 2 }
        model.tokens.removeAll { $0.name == "Home" }
        try await write([FileTag(name: "Work"), FileTag(name: "Home"), FileTag(name: "Elsewhere")], a, ui)
        await model.reload()
        XCTAssertEqual(model.tokens.map(\.name), ["Work"], "the pending removal survives the reload")
        await model.commit()
        let onDisk = try await read(a, ui)
        XCTAssertEqual(onDisk.map(\.name), ["Work", "Elsewhere"], "only the user's edit is applied")
        XCTAssertEqual(model.tokens.map(\.name), ["Work", "Elsewhere"])
    }

    /// The field commits what it shows relative to what it showed when editing started, so a reload that happened
    /// meanwhile (adding a tag the field never displayed) is not reverted.
    func testCommitFromStaleFieldRebasesOntoReloadedTags() async throws {
        let ui = try await ContentTestHarness.make(self)
        let a = try ui.file("a.txt")
        try await write([FileTag(name: "Work")], a, ui)
        let model = TagEditorModel(urls: [a], context: ui.context)
        try await ui.waitUntil("model loaded") { model.tokens.count == 1 }
        let shown = model.tokens
        try await write([FileTag(name: "Work"), FileTag(name: "Elsewhere")], a, ui)
        await model.reload()
        model.stage(edited: [FileTag(name: "Work"), FileTag(name: "New")], shown: shown)
        await model.commit()
        let onDisk = try await read(a, ui)
        XCTAssertEqual(onDisk.map(\.name), ["Work", "Elsewhere", "New"])
    }

    func testRecolorEditKeepsNameSpellingAndOtherTags() {
        let edit = TagEdit.recolor(FileTag(name: "work", color: .green))
        XCTAssertEqual(edit.applied(to: [FileTag(name: "Home"), FileTag(name: "Work", color: .red)]),
                       [FileTag(name: "Home"), FileTag(name: "Work", color: .green)])
        XCTAssertEqual(edit.applied(to: [FileTag(name: "Home")]), [FileTag(name: "Home")], "never adds the tag")
    }

    func testEditorCompletionsFilterKnownTagsByPrefix() async throws {
        let ui = try await ContentTestHarness.make(self)
        let a = try ui.file("a.txt")
        ui.context.environment.settings.noteTagUsed(FileTag(name: "Groceries"))
        let model = TagEditorModel(urls: [a], context: ui.context)
        XCTAssertEqual(model.completions(for: "gr"), ["Groceries", "Green", "Gray"])
        XCTAssertEqual(model.completions(for: "  "), [])
    }

    func testEditTagsShowsPopoverForSelection() async throws {
        let ui = try await ContentTestHarness.make(self)
        try ui.file("a.txt")
        let window = try await ui.openBrowserWindow()
        window.session.folder.select(.names(["a.txt"]))
        let controller = FileCommandController(context: ui.context, window: window)
        XCTAssertTrue(controller.canPerform(.editTags, target: .contentSelection(window.session.folder)))
        controller.perform(.editTags, target: .contentSelection(window.session.folder), sender: nil)
        let popover = try XCTUnwrap(controller.tagPopover)
        XCTAssertTrue(popover.isShown)
        XCTAssertEqual((popover.contentViewController as? TagEditorPopoverController)?.model.urls, [ui.url("a.txt")])
        popover.close()
    }

    func testContextMenuHasTagsSubmenuAndPrefetches() async throws {
        let ui = try await ContentTestHarness.make(self)
        let a = try ui.file("a.txt")
        let content = try ui.content(of: try await ui.openBrowserWindow())
        let menu = try XCTUnwrap(content.contextMenu(forRow: 0))
        let tags = try XCTUnwrap(menu.items.first { $0.identifier?.rawValue == "macx.menu.tags" })
        XCTAssertEqual(tags.title, L10n.string("Tags"))
        XCTAssertEqual(tags.submenu?.items.last?.title, L10n.string("Edit Tags…"))
        let cache = ui.context.environment.tagCache
        try await ui.waitUntil("selection prefetched") { cache.cachedTags(for: a) != nil }
    }

    func testPropertiesHasTagEditorForItemsOnly() async throws {
        let ui = try await ContentTestHarness.make(self)
        let a = try ui.file("a.txt"), b = try ui.file("b.txt")
        let one = PropertiesViewModel(subject: .items([a]), environment: ui.context.environment)
        XCTAssertEqual(one.tagEditor?.urls, [a])
        let two = PropertiesViewModel(subject: .items([a, b]), environment: ui.context.environment)
        XCTAssertEqual(two.tagEditor?.urls, [a, b])
        let volume = try XCTUnwrap(ui.context.environment.volumes.list.first)
        XCTAssertNil(PropertiesViewModel(subject: .volume(volume), environment: ui.context.environment).tagEditor)
        one.close(); two.close()
    }

    func testTagDotsViewLayout() {
        let v = TagDotsView(frame: NSRect(x: 0, y: 0, width: 60, height: 16))
        v.tags = [FileTag(name: "A", color: .red), FileTag(name: "B", color: .blue), FileTag(name: "C"),
                  FileTag(name: "D", color: .green), FileTag(name: "E", color: .gray)]
        XCTAssertEqual(v.dotColors.count, 3)            // colourless tags are skipped for dots
        XCTAssertEqual(v.dotColors, [.blue, .green, .gray], "the most recently added last (drawn on top)")
        XCTAssertEqual(v.overflowText, "+1")
        XCTAssertEqual(v.accessibilityLabel(), "A, B, C, D, E")
        v.tags = [FileTag(name: "A", color: .red)]
        XCTAssertNil(v.overflowText)
        v.tags = []
        XCTAssertEqual(v.dotColors, [])
        XCTAssertNil(v.overflowText)
    }

    func testTagsColumnShowsDotsFromFolderAttributes() async throws {
        let ui = try await ContentTestHarness.make(self)
        let a = try ui.file("a.txt")
        try await write([FileTag(name: "Red", color: .red), FileTag(name: "Work")], a, ui)
        let window = try await ui.openBrowserWindow()
        window.session.updateViewState { state in
            if let i = state.columns.firstIndex(where: { $0.id == .tags }) { state.columns[i].visible = true }
            else { state.columns.append(ColumnSetting(id: .tags, width: ColumnID.tags.defaultWidth, visible: true)) }
        }
        let content = try ui.content(of: window)
        let details = try XCTUnwrap(content.activeList as? DetailsViewController)
        try await ui.waitUntil("tags read") { details.cellText(rowNamed: "a.txt", column: "tags") == "Red, Work" }
        let dots = { (details.cellView(row: 0, column: .tags) as? TagsCellView)?.dots }
        try await ui.waitUntil("dots drawn") { dots()?.dotColors == [.red] }
        XCTAssertEqual(dots()?.tags.map(\.name), ["Red", "Work"])
        XCTAssertEqual(details.cellView(row: 0, column: .tags)?.textField?.stringValue, "Red, Work")
        // A tag job from the app redraws the row (xattr-only change: the watcher event re-reads it).
        let controller = FileCommandController(context: ui.context, window: window)
        await controller.applyTagEdit(.add(FileTag(name: "Blue", color: .blue)), to: [a])
        try await ui.waitUntil("dots follow the job") { dots()?.dotColors == [.red, .blue] }
    }
}

/// Synchronous tag read for wait conditions (a fresh lane pool per call would be heavier; xattr reads are tiny).
enum TagIOTestRead {
    static func sync(_ url: URL) throws -> [FileTag] {
        let path = url.path(percentEncoded: false)
        let size = getxattr(path, TagIO.xattrName, nil, 0, 0, XATTR_NOFOLLOW)
        if size < 0 {
            if errno == ENOATTR { return [] }
            throw TagIOError(code: errno)
        }
        var buffer = [UInt8](repeating: 0, count: size)
        let n = getxattr(path, TagIO.xattrName, &buffer, size, 0, XATTR_NOFOLLOW)
        guard n >= 0 else { throw TagIOError(code: errno) }
        return TagIO.decode(Data(buffer.prefix(n)))
    }
}
