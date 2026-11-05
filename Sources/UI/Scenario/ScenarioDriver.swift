import AppKit
import Core
import Darwin
import MacxFS

struct KeyCandidate: Equatable, Sendable {
    var isVisible: Bool
    var isSheet: Bool
    var canBecomeKey: Bool
    var isPanel: Bool
}

struct UIScenarioResult: Codable, Equatable {
    var name: String
    var passed = false
    var failedStep: Int?
    var message: String?
    var durationMs = 0
    var activated = false        // additive: did macOS actually activate the process?
}

struct DriverError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// In-process UI scenario runner (§9 UI smoke suite). Started by ScenarioLaunch when --scenario is set.
@MainActor
final class ScenarioDriver {
    static let fenceSubtype: Int16 = 0x4D58
    private let context: UIContext
    private let file: URL
    private let output: URL
    private var rootReal: URL?
    private var rootPrefixes: [String] = []
    private var decorator: ScenarioInteraction?
    private var contextMenu: NSMenu?
    private var fenceWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var nextFence = 1
    private var monitor: Any?
    private var knownWindows: Set<ObjectIdentifier> = []

    init(context: UIContext, file: URL, output: URL) {
        self.context = context
        self.file = file
        self.output = output
    }

    // MARK: pure helpers (unit-tested)

    nonisolated static func pickKeyWindow(_ candidates: [KeyCandidate]) -> Int? {
        candidates.firstIndex { $0.isVisible && !$0.isSheet && $0.canBecomeKey && !$0.isPanel }
    }

    /// `path` relative to whichever spelling of the root matches (/var/... vs /private/var/...); nil if outside.
    nonisolated static func relativePath(_ path: String, roots: [String]) -> String? {
        for root in roots {
            if path == root { return "" }
            if path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        }
        return nil
    }

    /// A drop's resolved destination (DropDestinationResolver) must be --root or inside it (QA round 2: "crumb:<n>"
    /// above the root and sidebar favorites resolved to real folders outside the sandbox).
    nonisolated static func confinedDropDestination(_ url: URL?, onto: String, roots: [String]) throws(DriverError) -> URL {
        guard let url else { throw DriverError("drop target '\(onto)' does not resolve to a folder") }
        let path = url.standardizedFileURL.path(percentEncoded: false)
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        guard relativePath(trimmed, roots: roots) != nil else {
            throw DriverError("drop target '\(onto)' resolves to \(trimmed), outside --root")
        }
        return url
    }

    /// Indices of steps that do not have exactly one action field (ScenarioFile.validate reports the first as an error).
    nonisolated static func validateSteps(_ steps: [ScenarioFile.Step]) -> [Int] {
        steps.indices.filter { steps[$0].actions.count != 1 }
    }

    /// §2.4 tokens: "{root}" = POSIX path of --root as the app holds it (no trailing slash), "{rootURL}" = its file
    /// URL (trailing slash), "{user}" = NSUserName(). "{rootURL}" goes first because "{root}" is a prefix of it.
    nonisolated static func substitute(_ s: String, root: URL) -> String {
        guard s.contains("{") else { return s }
        var path = root.path(percentEncoded: false)
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return s.replacing("{rootURL}", with: URL(filePath: path, directoryHint: .isDirectory).absoluteString)
            .replacing("{root}", with: path)
            .replacing("{user}", with: NSUserName())
    }

    /// nil unless `relative` stays inside `root` lexically (non-empty, not absolute, no "..", ".", "~"). fs steps
    /// also check the symlink-resolved parent on a lane (a link inside the root may point out).
    nonisolated static func guardedURL(_ relative: String, root: URL) -> URL? {
        guard ScenarioPath.isSafeRelative(relative) else { return nil }
        let url = root.appending(path: relative).standardizedFileURL
        let rootPath = root.standardizedFileURL.path(percentEncoded: false)
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return url.path(percentEncoded: false).hasPrefix(prefix) ? url : nil
    }

    // MARK: run

    func run() async -> Bool {
        let clock = ContinuousClock()
        let started = clock.now
        var result = UIScenarioResult(name: file.deletingPathExtension().lastPathComponent)
        do {
            let scenario = try await loadScenario()
            result.name = scenario.name
            try await prepare(scenario.fixture)
            for (index, step) in scenario.steps.enumerated() {
                do {
                    try await perform(step)
                    try requireBrowsingInsideRoot()
                } catch {
                    result.failedStep = index
                    throw error
                }
            }
            result.passed = true
        } catch {
            result.message = String(describing: error)
        }
        let elapsed = (clock.now - started).components
        result.durationMs = Int(elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000)
        result.activated = NSRunningApplication.current.isActive
        await write(result)
        teardown()
        return result.passed
    }

    private var lanes: LanePool { context.environment.lanes }

    private func loadScenario() async throws -> ScenarioFile {
        let url = file
        let data = try await lanes.perform(on: .unknown) { _ in try Data(contentsOf: url) }
        return try ScenarioFile.load(data)
    }

    private func prepare(_ fixture: ScenarioFile.Fixture) async throws {
        guard let given = context.options.root else { throw DriverError("--scenario requires --root") }
        let real = try await lanes.perform(on: .unknown) { _ in
            let resolved = given.resolvingSymlinksInPath()
            try ScenarioFixtures.create(fixture, in: resolved)
            return resolved
        }
        rootReal = real
        rootPrefixes = [given.standardizedFileURL.path, real.standardizedFileURL.path]
        installRouting()
        let window = try browserWindow()
        window.session.reload()
        let expected = ScenarioFixtures.topLevelVisibleNames(fixture)
        try await waitUntil("the fixture is listed", timeout: .seconds(5)) {
            Set(window.probeRowNames) == expected && window.probeFolderState == .complete
        }
        focusList(in: window)
    }

    private func installRouting() {
        // No activation (P1-41 deviation): an activated scenario app takes the user's real keystrokes (they are
        // typing elsewhere while the suite runs), which corrupts the run. MacxApplication's pinned key window makes
        // every step work inactive (facts 4-5); `activated` in the result still records what macOS did.
        MacxApplication.scenarioKeyWindow = (try? browserWindow())?.window
        knownWindows = Set(NSApp.orderedWindows.map(ObjectIdentifier.init))
        monitor = NSEvent.addLocalMonitorForEvents(matching: .applicationDefined) { [weak self] event in
            guard event.subtype.rawValue == ScenarioDriver.fenceSubtype else { return event }
            self?.releaseFence(event.data1)
            return nil
        }
        let decorator = ScenarioInteraction(forwardingTo: context.interaction)
        context.installInteraction(decorator)
        self.decorator = decorator
        NotificationCenter.default.addObserver(self, selector: #selector(menuDidBeginTracking(_:)),
                                               name: NSMenu.didBeginTrackingNotification, object: nil)
    }

    @objc private func menuDidBeginTracking(_ note: Notification) {
        // A real popUpContextMenu (e.g. from a key or tracker) becomes the menu chooseMenuItem acts on.
        if let menu = note.object as? NSMenu, menu !== NSApp.mainMenu { contextMenu = menu }
    }

    private func teardown() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        NotificationCenter.default.removeObserver(self)
        MacxApplication.scenarioKeyWindow = nil
    }

    private func write(_ result: UIScenarioResult) async {
        guard let data = try? JSONEncoder().encode(result) else { return }
        let url = output
        _ = try? await lanes.perform(on: .unknown) { _ in try data.write(to: url, options: .atomic) }
    }

    // MARK: windows

    /// Pins a window that appeared since the last step (a Properties window opened by ⌘I), or re-picks the
    /// frontmost one when the pinned window went away. Otherwise the pinned window stays: a click step focused
    /// it on purpose, and a closing alert sheet or a window ordered above it must not steal the keys.
    private func refreshKeyWindow() {
        let windows = NSApp.orderedWindows
        let candidates = windows.map {
            KeyCandidate(isVisible: $0.isVisible, isSheet: $0.sheetParent != nil, canBecomeKey: $0.canBecomeKey, isPanel: $0 is NSPanel)
        }
        let fresh = windows.indices.filter { !knownWindows.contains(ObjectIdentifier(windows[$0])) }
        knownWindows = Set(windows.map(ObjectIdentifier.init))
        if let index = Self.pickKeyWindow(fresh.map { candidates[$0] }) {
            MacxApplication.scenarioKeyWindow = windows[fresh[index]]
            return
        }
        let pinned = MacxApplication.scenarioKeyWindow
        if let pinned, pinned.isVisible, windows.contains(where: { $0 === pinned }) { return }
        if let index = Self.pickKeyWindow(candidates) { MacxApplication.scenarioKeyWindow = windows[index] }
    }

    private func browserWindow() throws -> BrowserWindowController {
        let all = context.windows.windows
        if let key = MacxApplication.scenarioKeyWindow, let match = all.first(where: { $0.window === key }) { return match }
        if let first = all.first { return first }
        throw DriverError("no browser window is open")
    }

    private func keyWindowNumber() throws -> Int {
        if let key = MacxApplication.scenarioKeyWindow { return key.windowNumber }
        guard let number = try browserWindow().window?.windowNumber else { throw DriverError("browser window has no NSWindow") }
        return number
    }

    private func listView(in controller: BrowserWindowController) -> NSView? {
        guard let root = controller.window?.contentView else { return nil }
        let ids: Set<String> = [AXID.detailsTable, AXID.iconsGrid]
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            let id = view.accessibilityIdentifier()
            if (ids.contains(id) || ids.contains(view.identifier?.rawValue ?? "")) && !view.isHiddenOrHasHiddenAncestor {
                return (view as? NSScrollView)?.documentView ?? view
            }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }

    private func focusList(in controller: BrowserWindowController) {
        MacxApplication.scenarioKeyWindow = controller.window
        controller.window?.makeKeyAndOrderFront(nil)
        if let list = listView(in: controller) { controller.window?.makeFirstResponder(list) }
    }

    private func contentController(in controller: BrowserWindowController) -> ContentViewController? {
        var responder: NSResponder? = listView(in: controller)
        while let r = responder {
            if let content = r as? ContentViewController { return content }
            responder = r.nextResponder
        }
        return nil
    }

    // MARK: fences and waits

    private func releaseFence(_ id: Int) { fenceWaiters.removeValue(forKey: id)?.resume() }

    /// Waits until every event posted before it has been dispatched (or 2 s, e.g. a modal loop swallowed it).
    private func fence() async {
        guard let number = try? keyWindowNumber() else { return }
        let id = nextFence
        nextFence += 1
        guard let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                             windowNumber: number, context: nil, subtype: Self.fenceSubtype,
                                             data1: id, data2: 0) else { return }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.releaseFence(id)
        }
        await withCheckedContinuation { continuation in
            fenceWaiters[id] = continuation
            NSApp.postEvent(event, atStart: false)
        }
        timer.cancel()
    }

    private func waitUntil(_ what: String, timeout: Duration, _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now >= deadline { throw DriverError("timed out after \(timeout) waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func milliseconds(_ ms: Int?, default fallback: Int) -> Duration { .milliseconds(ms ?? fallback) }

    // MARK: steps

    private func perform(_ step: ScenarioFile.Step) async throws {
        refreshKeyWindow()
        if let key = step.key { try await sendKey(key) }
        else if let text = step.type { try await typeText(text) }
        else if let path = step.menu { try performMenu(path: path); await fence() }
        else if let command = step.command { try performCommand(command); await fence() }
        else if let name = step.click { try await click(name, modifiers: step.modifiers ?? []) }
        else if let name = step.doubleClick { try await doubleClick(name); await fence() }
        else if let name = step.rightClick { try await openContextMenu(on: name) }
        else if let target = step.middleClick { try middleClick(target); await fence() }
        else if let index = step.selectTab { try selectTab(index); await fence() }
        else if let write = step.fsWrite { try await fsWrite(write) }
        else if let tags = step.fsTags { try await fsTags(tags) }
        else if let title = step.chooseMenuItem { try chooseMenuItem(title); await fence() }
        else if let drop = step.drop { try await performDrop(drop, modifiers: step.modifiers ?? []) }
        else if let action = step.answerConflict {
            try await answerConflict(action, all: step.applyToAll ?? false, timeout: milliseconds(step.timeoutMs, default: 5_000))
        }
        else if let title = step.answerAlert { try await answerAlert(title, timeout: milliseconds(step.timeoutMs, default: 3_000)) }
        else if let expectation = step.waitFor { try await waitFor(expectation, timeout: milliseconds(step.timeoutMs, default: 3_000)) }
        else if let raw = step.expect {
            let expectation = substituted(raw)
            let problems = ExpectationMatcher.mismatches(expectation, try await snapshot(for: expectation))
            if !problems.isEmpty { throw DriverError(problems.joined(separator: "; ")) }
        }
        else if let ms = step.sleepMs { try await Task.sleep(for: .milliseconds(ms)) }
    }

    /// Safety net for the C3 rule: a step that left a window browsing outside --root fails the run before any
    /// later step (delete, rename, drop) could act there.
    private func requireBrowsingInsideRoot() throws {
        for window in context.windows.windows {
            let path = window.probeFolderURL.standardizedFileURL.path
            if Self.relativePath(path, roots: rootPrefixes) == nil { throw DriverError("a window left --root: it browses \(path)") }
        }
    }

    private func post(_ keys: [SynthKey]) throws {
        let number = try keyWindowNumber()
        for key in keys { for event in KeySynth.events(key, windowNumber: number) { NSApp.postEvent(event, atStart: false) } }
    }

    private func sendKey(_ text: String) async throws {
        guard let chord = KeyChord(parsing: text), let key = KeySynth.spec(for: chord) else { throw DriverError("cannot synthesize '\(text)'") }
        try post([key])
        await fence()
    }

    private func typeText(_ text: String) async throws {
        try post(KeySynth.typingSpecs(text))
        await fence()
    }

    private func invoke(_ item: NSMenuItem, in menu: NSMenu) throws {
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
        guard item.isEnabled else { throw DriverError("menu item '\(item.title)' is disabled") }
        let index = menu.index(of: item)
        guard index >= 0 else { throw DriverError("menu item '\(item.title)' left its menu") }
        menu.performActionForItem(at: index)
    }

    private func performMenu(path: [String]) throws {
        guard var menu = NSApp.mainMenu else { throw DriverError("no main menu") }
        for (i, title) in path.enumerated() {
            guard let item = menu.items.first(where: { $0.title == title || $0.submenu?.title == title }) else {
                throw DriverError("menu '\(title)' not found among \(menu.items.map { $0.submenu?.title ?? $0.title })")
            }
            if i == path.count - 1 { return try invoke(item, in: menu) }
            guard let sub = item.submenu else { throw DriverError("'\(title)' has no submenu") }
            sub.delegate?.menuNeedsUpdate?(sub)
            menu = sub
        }
    }

    private func findItem(_ menu: NSMenu, _ matches: (NSMenuItem) -> Bool) -> (NSMenuItem, NSMenu)? {
        menu.delegate?.menuNeedsUpdate?(menu)
        for item in menu.items {
            if matches(item) { return (item, menu) }
            if let sub = item.submenu, let found = findItem(sub, matches) { return found }
        }
        return nil
    }

    private func performCommand(_ raw: String) throws {
        guard let command = Command(rawValue: raw), let main = NSApp.mainMenu else { throw DriverError("unknown command '\(raw)'") }
        let selector = Selector(command.selectorName)
        guard let (item, menu) = findItem(main, { $0.action == selector }) else {
            throw DriverError("no main-menu item for command \(raw) (\(command.selectorName))")
        }
        try invoke(item, in: menu)
    }

    /// The row's index, waiting up to 3 s for it: after a navigation `waitFor {"folder"}` can pass before the
    /// new folder's rows are listed.
    private func row(named name: String, in controller: BrowserWindowController) async throws -> Int {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(3)
        while true {
            if let row = controller.probeRowNames.firstIndex(of: name) { return row }
            if clock.now >= deadline { throw DriverError("no row named '\(name)' in \(controller.probeRowNames)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Model-level click: the SelectionCommand P1-33 maps the click to (fact 4: synthesized clicks don't work inactive).
    private func click(_ name: String, modifiers: [String]) async throws {
        let controller = try browserWindow()
        if case .prefixed(let target) = ScenarioTarget(parsing: name) {
            guard let hook = controller.scenarioHooks.clickTarget else {
                throw DriverError("click '\(target)': ScenarioHooks.clickTarget is not installed")
            }
            guard hook(target, modifiers) else { throw DriverError("click target '\(target)' not found") }
            await fence()
            return
        }
        let row = try await row(named: name, in: controller)
        let command: SelectionCommand =
            modifiers.contains("cmd") ? .toggle(row)
            : modifiers.contains("shift") ? .extend(to: row)
            : .set(IndexSet(integer: row), cursor: row)
        controller.session.folder.select(command)
        focusList(in: controller)
    }

    private func doubleClick(_ name: String) async throws {
        try await click(name, modifiers: [])
        guard NSApp.sendAction(Selector(Command.open.selectorName), to: nil, from: nil) else {
            throw DriverError("\(Command.open.selectorName) was not handled by the responder chain")
        }
    }

    private func openContextMenu(on name: String) async throws {
        let controller = try browserWindow()
        if case .prefixed(let target) = ScenarioTarget(parsing: name) {
            guard let hook = controller.scenarioHooks.rightClickTarget else {
                throw DriverError("rightClick '\(target)': ScenarioHooks.rightClickTarget is not installed")
            }
            guard hook(target) else { throw DriverError("right-click target '\(target)' not found") }
            return
        }
        guard let content = contentController(in: controller), let handler = content.handler else {
            throw DriverError("content view controller or its command handler not found")
        }
        let folder = controller.session.folder
        let builder = ContextMenuBuilder(context: context)
        if name.isEmpty {
            contextMenu = builder.emptySpaceMenu(for: folder, handler: handler)
        } else {
            let row = try await row(named: name, in: controller)
            if !folder.selection.rows.contains(row) { folder.select(.set(IndexSet(integer: row), cursor: row)) }
            contextMenu = builder.itemMenu(for: folder.selection.rows, in: folder, handler: handler)
        }
        focusList(in: controller)
    }

    private func chooseMenuItem(_ title: String) throws {
        guard let menu = contextMenu else { throw DriverError("no context menu is open") }
        guard let (item, owner) = findItem(menu, { $0.title == title }) else {
            throw DriverError("'\(title)' not in the context menu: \(menu.items.map(\.title))")
        }
        menu.cancelTracking()
        contextMenu = nil
        try invoke(item, in: owner)
    }

    private func performDrop(_ drop: ScenarioFile.Drop, modifiers: [String]) async throws {
        let controller = try browserWindow()
        let folderURL = controller.probeFolderURL
        var mods = DragModifiers()
        if modifiers.contains("opt") { mods.insert(.option) }
        if modifiers.contains("cmd") { mods.insert(.command) }
        if modifiers.contains("ctrl") { mods.insert(.control) }
        let choice: DragOperation? = try drop.choose.map { raw -> DragOperation in
            switch raw {
            case "copy": .copy
            case "move": .move
            case "alias": .alias
            case "cancel": DragOperation.none
            default: throw DriverError("unsupported drop choice '\(raw)' (Contract note C5)")
            }
        }
        let sources = drop.sources.map { folderURL.appending(path: $0).standardizedFileURL }
        for source in sources where Self.relativePath(source.path, roots: rootPrefixes) == nil {
            throw DriverError("drop source \(source.path) is outside --root")
        }
        // The destination too, lexically and after resolving symlinks (a link row inside the root may point out).
        let resolved = DropDestinationResolver.resolve(drop.onto, folder: controller.session.folder,
                                                       favorites: context.environment.settings.favorites)
        let destination = try Self.confinedDropDestination(resolved, onto: drop.onto, roots: rootPrefixes)
        let real = try await lanes.perform(on: .unknown) { _ in destination.resolvingSymlinksInPath() }
        _ = try Self.confinedDropDestination(real, onto: drop.onto, roots: rootPrefixes)
        await controller.probePerformDrop(sources: sources, onto: drop.onto,
                                          modifiers: mods, secondary: drop.secondary ?? false, menuChoice: choice)
        await fence()
    }

    private func middleClick(_ target: String) throws {
        let controller = try browserWindow()
        guard let hook = controller.scenarioHooks.performMiddleClick else {
            throw DriverError("middleClick '\(target)': ScenarioHooks.performMiddleClick is not installed")
        }
        guard hook(target) else { throw DriverError("middle-click target '\(target)' not found") }
    }

    private func selectTab(_ index: Int) throws {
        guard let window = try browserWindow().window else { throw DriverError("browser window has no NSWindow") }
        let tabs = BrowserWindowController.orderedTabWindows(of: window)
        guard tabs.indices.contains(index) else { throw DriverError("no tab \(index): the window has \(tabs.count) tab(s)") }
        let tab = tabs[index]
        MacxApplication.scenarioKeyWindow = tab
        tab.makeKeyAndOrderFront(nil)
        if let controller = tab.windowController as? BrowserWindowController { focusList(in: controller) }
    }

    /// The guarded target of an fs step: lexically inside the root, and its existing parent resolves inside it too.
    private func fsTarget(_ relative: String) async throws -> URL {
        guard let root = rootReal, let url = Self.guardedURL(relative, root: root) else {
            throw DriverError("fs step: path '\(relative)' is outside root")
        }
        let roots = rootPrefixes
        let parent = try await lanes.perform(on: .unknown) { _ in url.deletingLastPathComponent().resolvingSymlinksInPath() }
        guard Self.relativePath(parent.standardizedFileURL.path(percentEncoded: false), roots: roots) != nil else {
            throw DriverError("fs step: path '\(relative)' resolves outside root (\(parent.path(percentEncoded: false)))")
        }
        return parent.appending(path: url.lastPathComponent)
    }

    private func fsWrite(_ write: ScenarioFile.FSWrite) async throws {
        let url = try await fsTarget(write.path)
        let bytes = write.bytes
        try await lanes.perform(on: .unknown) { _ in try ScenarioFixtures.writeZeros(bytes, at: url) }
    }

    private func fsTags(_ step: ScenarioFile.FSTags) async throws {
        let url = try await fsTarget(step.path)
        let tags = step.tags, path = step.path
        try await lanes.perform(on: .unknown) { _ in try ScenarioFixtures.setFinderTags(tags, at: url, relative: path) }
    }

    private func answerConflict(_ raw: String, all: Bool, timeout: Duration) async throws {
        guard let action = ConflictAction(rawValue: raw), let decorator else { throw DriverError("bad conflict answer '\(raw)'") }
        try await waitUntil("a conflict to be asked", timeout: timeout) { decorator.pendingCount > 0 }
        let controller = try browserWindow()
        try await waitUntil("the conflict dialog on the origin window", timeout: .seconds(3)) {
            controller.window?.attachedSheet != nil
        }
        _ = decorator.answer(all ? .all(action) : .one(action))
        if let window = controller.window, let sheet = window.attachedSheet { window.endSheet(sheet) }
        await fence()
    }

    private func buttons(in view: NSView) -> [NSButton] {
        ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap { buttons(in: $0) }
    }

    private func answerAlert(_ title: String, timeout: Duration) async throws {
        var found: [String] = []
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            var windows: [NSWindow] = []
            if let modal = NSApp.modalWindow { windows.append(modal) }
            windows += context.windows.windows.compactMap { $0.window?.attachedSheet }
            for window in windows {
                guard let root = window.contentView else { continue }
                let candidates = buttons(in: root)
                found = candidates.map(\.title)
                if let button = candidates.first(where: { $0.title == title && $0.isEnabled }) {
                    button.performClick(nil)
                    await fence()
                    return
                }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw DriverError("no alert button '\(title)' (buttons seen: \(found))")
    }

    private func waitFor(_ raw: ScenarioFile.Expectation, timeout: Duration) async throws {
        let expectation = substituted(raw)
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var problems: [String] = []
        repeat {
            problems = ExpectationMatcher.mismatches(expectation, try await snapshot(for: expectation))
            if problems.isEmpty { return }
            try await Task.sleep(for: .milliseconds(20))
        } while clock.now < deadline
        throw DriverError("after \(timeout): " + problems.joined(separator: "; "))
    }

    private func substituted(_ e: ScenarioFile.Expectation) -> ScenarioFile.Expectation {
        guard let root = context.options.root else { return e }
        return e.substituted(root: root)
    }

    private func relativeOrMarked(_ url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        return Self.relativePath(trimmed, roots: rootPrefixes) ?? "<outside root: \(trimmed)>"
    }

    /// Phase 2 values (§2.4). Hook-backed ones stay nil while the hook is missing.
    private func addPhase2(to s: inout ProbeSnapshot, from w: BrowserWindowController, for e: ScenarioFile.Expectation) {
        s.tabs = w.probeTabFolderURLs.map(relativeOrMarked)
        s.activeTab = w.probeSelectedTabIndex
        s.sort = ScenarioStrings.sort(w.probeSort)
        s.iconSize = w.probeIconSize.rawValue
        s.groupBy = w.probeGrouping.rawValue
        let hooks = w.scenarioHooks
        s.groups = hooks.groupHeaderTitles?()
        s.visibleRows = hooks.visibleRowNames?()
        s.visibleColumns = hooks.visibleColumnIDs?()
        if let state = hooks.quickLookState?() {
            s.quickLookVisible = state.visible
            s.quickLookItems = state.items
        }
        if let cellText = hooks.cellText, let wanted = e.cells {
            var cells: [String: [String: String]] = [:]
            for (row, columns) in wanted {
                for column in columns.keys { if let text = cellText(row, column) { cells[row, default: [:]][column] = text } }
            }
            s.cells = cells
        }
        if let chain = hooks.columnsChain?() {
            s.columnsChain = chain.folders.map(relativeOrMarked)
            s.activeColumn = chain.active
        }
        s.thumbnails = hooks.thumbnailNames?()
        s.pasteboardText = nil    // P2-04 adds PasteboardBackend.readString()
    }

    private func snapshot(for expectation: ScenarioFile.Expectation) async throws -> ProbeSnapshot {
        let w = try browserWindow()
        var s = ProbeSnapshot()
        s.rows = w.probeRowNames
        s.selection = w.probeSelectedNames
        s.cut = w.probeCutNames
        s.folder = Self.relativePath(w.probeFolderURL.standardizedFileURL.path, roots: rootPrefixes)
        s.state = ScenarioStrings.state(w.probeFolderState)
        s.focus = ScenarioStrings.focus(w.probeFocus)
        s.fieldEditorText = w.probeFieldEditorText
        s.renameText = w.probeRenameText
        s.emptyState = w.probeEmptyStateText
        s.banner = w.probeBannerText
        s.editingAddress = w.probeIsEditingAddress
        s.viewMode = w.probeViewMode.rawValue
        s.sheetPresent = w.window?.attachedSheet != nil
        s.propertiesWindows = NSApp.windows.filter {
            $0.isVisible && ($0.identifier?.rawValue == AXID.propertiesWindow || $0.accessibilityIdentifier() == AXID.propertiesWindow)
        }.count
        s.windowCount = context.windows.windows.count
        addPhase2(to: &s, from: w, for: expectation)
        let paths = ExpectationMatcher.requestedPaths(expectation).filter(ScenarioPath.isSafeRelative)
        if !paths.isEmpty, let root = rootReal {
            s.fileSizes = try await lanes.perform(on: .unknown) { _ in
                var sizes: [String: Int] = [:]
                for path in paths {
                    var st = stat()
                    if lstat(root.appending(path: path).path, &st) == 0 { sizes[path] = Int(st.st_size) }
                }
                return sizes
            }
        }
        return s
    }
}
