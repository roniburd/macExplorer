import XCTest
import AppKit
import Darwin
@testable import UI
import Core
import MacxFS
import MacxFixtures

enum HarnessError: Error { case timeout(String), posix(String, Int32) }

/// Global Constraints S5-C1: every S5 test builds its world here, and all writes stay under `sandbox.root`.
@MainActor
final class ContentTestHarness {
    let sandbox: Sandbox
    let filesRoot: URL
    let environment: CoreEnvironment
    let context: UIContext
    let pasteboardName: String
    /// environment.interaction's target in every UI test (S5-C1): never a modal alert.
    let interaction = ScriptedInteraction()
    private var hostedWindows: [NSWindow] = []
    private var models: [FolderModel] = []
    private var lockedPaths: [String] = []
    private var restrictedPaths: [String] = []

    static func make(_ testCase: XCTestCase) async throws -> ContentTestHarness {
        let harness = try ContentTestHarness()
        testCase.addTeardownBlock { @MainActor in await harness.tearDown() }
        _ = await harness.environment.start()
        return harness
    }

    static func requireWindowServer() throws {
        if NSScreen.screens.isEmpty { throw XCTSkip("needs a GUI login session (window server)") }
    }

    private init() throws {
        _ = NSApplication.shared
        // The only calls into the P1-02 Sandbox API (S1 P1-02 Interfaces, exact): Sandbox(prefix:), .root,
        // .createDirectory(_:), .createFile(_:contents:), plus .destroy() in tearDown.
        sandbox = try Sandbox(prefix: "macx-tests")
        filesRoot = try sandbox.createDirectory("files")
        environment = CoreEnvironment.sandboxed(root: sandbox.root)
        pasteboardName = "macx-tests-\(UUID().uuidString)"
        var options = LaunchOptions()
        options.root = filesRoot
        options.stateDirectory = sandbox.root.appending(path: "state", directoryHint: .isDirectory)
        options.sandboxTrash = sandbox.root.appending(path: ".trash", directoryHint: .isDirectory)
        options.pasteboardName = pasteboardName
        options.fakeLaunchServices = true
        options.skipOnboarding = true
        context = UIContext(environment: environment, options: options)
        environment.interaction.setTarget(interaction)
    }

    func url(_ relative: String) -> URL {
        relative.isEmpty ? filesRoot : filesRoot.appending(path: relative)
    }

    @discardableResult
    func file(_ relative: String, bytes: Int = 1) throws -> URL {
        try sandbox.createFile("files/" + relative, contents: Data(repeating: 0x78, count: bytes))
    }

    @discardableResult
    func dir(_ relative: String) throws -> URL {
        try sandbox.createDirectory("files/" + relative)
    }

    /// chflags on a harness path (UF_HIDDEN, UF_IMMUTABLE). Locked paths are unlocked again in tearDown.
    func setFlags(_ relative: String, _ flags: Int32) throws {
        let path = url(relative).path
        guard chflags(path, UInt32(flags)) == 0 else { throw HarnessError.posix("chflags \(path)", errno) }
        if flags & UF_IMMUTABLE != 0 { lockedPaths.append(path) }
    }

    /// chmod on a harness path; restored to 0755 in tearDown so the sandbox can be removed.
    func setMode(_ relative: String, _ mode: mode_t) throws {
        let path = url(relative).path
        guard chmod(path, mode) == 0 else { throw HarnessError.posix("chmod \(path)", errno) }
        restrictedPaths.append(path)
    }

    func exists(_ relative: String) -> Bool {
        var st = Darwin.stat()
        return lstat(url(relative).path, &st) == 0
    }

    func lstatInfo(_ relative: String) -> Darwin.stat? {
        var st = Darwin.stat()
        return lstat(url(relative).path, &st) == 0 ? st : nil
    }

    func openFolder(_ relative: String = "", query: ViewQuery = ViewQuery()) async throws -> FolderModel {
        let model = environment.makeFolderModel(url(relative), query: query)
        models.append(model)
        model.start()
        try await waitUntil("folder '\(relative)' complete") { model.state == .complete }
        return model
    }

    /// An offscreen window (never ordered front) hosting `controller`.
    @discardableResult
    func host(_ controller: NSViewController, size: NSSize = NSSize(width: 900, height: 600)) throws -> NSWindow {
        try Self.requireWindowServer()
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(size)
        window.layoutIfNeeded()
        hostedWindows.append(window)
        return window
    }

    func makeContent(_ relative: String = "", size: NSSize = NSSize(width: 900, height: 600))
        async throws -> (ContentViewController, BrowserSession, NSWindow) {
        try Self.requireWindowServer()
        let session = BrowserSession(environment: environment, initialURL: url(relative))
        let content = ContentViewController(context: context, session: session)
        let window = try host(content, size: size)
        try await waitUntil("session folder complete") { session.folder.state == .complete }
        return (content, session, window)
    }

    /// A real browser window from WindowManager (ordered front by S4 code; closed in tearDown).
    func openBrowserWindow(_ relative: String = "") async throws -> BrowserWindowController {
        try Self.requireWindowServer()
        let controller = context.windows.openWindow(at: url(relative))
        try await waitUntil("window folder complete") { controller.session.folder.state == .complete }
        return controller
    }

    func content(of controller: BrowserWindowController) throws -> ContentViewController {
        try XCTUnwrap(controller.contentViewController?.firstDescendant(of: ContentViewController.self))
    }

    func waitUntil(_ what: String, timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { throw HarnessError.timeout(what) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func tearDown() async {
        PropertiesWindowController.closeAll(for: context)
        for controller in context.windows.windows { controller.close() }
        for window in hostedWindows { window.close() }
        for model in models { model.close() }
        await environment.fileOps.waitUntilIdle()
        for path in lockedPaths { _ = chflags(path, 0) }
        for path in restrictedPaths { _ = chmod(path, 0o755) }
        NSPasteboard(name: NSPasteboard.Name(pasteboardName)).releaseGlobally()
        RecordingURLOpener.shared.reset()
        sandbox.destroy()
    }
}
