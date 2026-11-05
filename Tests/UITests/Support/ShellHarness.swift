import XCTest
import AppKit
@testable import UI
import Core
import MacxFS
import MacxFixtures

enum ShellHarnessError: Error { case timeout(String) }

/// P1-26 window-shell tests build their world here. Every file lives under `sandbox.root` (a fresh
/// `macx-tests-<UUID>` temp dir); fixture files go in `<sandbox>/files` so `state/` and `.trash/` never show up.
@MainActor
final class ShellHarness {
    let sandbox: Sandbox
    let filesRoot: URL
    let environment: CoreEnvironment
    let context: UIContext
    let interaction = ScriptedInteraction()

    static func make(_ testCase: XCTestCase, start: Bool = true, configure: (inout LaunchOptions) -> Void = { _ in })
        async throws -> ShellHarness {
        let harness = try ShellHarness(configure: configure)
        testCase.addTeardownBlock { @MainActor in await harness.tearDown() }
        if start { _ = await harness.environment.start() }
        return harness
    }

    static func requireWindowServer() throws {
        _ = NSApplication.shared
        if NSScreen.screens.isEmpty { throw XCTSkip("needs a GUI login session (window server)") }
    }

    private init(configure: (inout LaunchOptions) -> Void) throws {
        _ = NSApplication.shared
        sandbox = try Sandbox(prefix: "macx-tests")
        filesRoot = try sandbox.createDirectory("files")
        environment = CoreEnvironment.sandboxed(root: sandbox.root)
        var options = LaunchOptions()
        options.root = filesRoot
        options.stateDirectory = sandbox.root.appending(path: "state", directoryHint: .isDirectory)
        options.sandboxTrash = sandbox.root.appending(path: ".trash", directoryHint: .isDirectory)
        options.pasteboardName = "macx-tests-\(UUID().uuidString)"
        options.fakeLaunchServices = true
        options.skipOnboarding = true
        configure(&options)
        context = UIContext(environment: environment, options: options)
        // BasicAlertInteraction would show modal alerts; tests answer from a script.
        context.installInteraction(interaction)
    }

    func url(_ relative: String) -> URL {
        relative.isEmpty ? filesRoot : filesRoot.appending(path: relative, directoryHint: .isDirectory)
    }

    @discardableResult func file(_ relative: String) throws -> URL { try sandbox.createFile("files/" + relative) }
    @discardableResult func dir(_ relative: String) throws -> URL { try sandbox.createDirectory("files/" + relative) }

    func openWindow(_ relative: String = "", selecting name: String? = nil) async throws -> BrowserWindowController {
        try Self.requireWindowServer()
        let controller = context.windows.openWindow(at: url(relative), selecting: name)
        try await waitUntil("window folder complete") { controller.session.folder.state == .complete }
        return controller
    }

    func waitUntil(_ what: String, timeout: Duration = .seconds(30), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { throw ShellHarnessError.timeout(what) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    static func names(_ folder: FolderModel) -> [String] { (0..<folder.rowCount).map { folder.name(atRow: $0) } }

    func tearDown() async {
        for controller in context.windows.windows { controller.close() }
        await environment.fileOps.waitUntilIdle()
        if let name = context.options.pasteboardName { NSPasteboard(name: NSPasteboard.Name(name)).releaseGlobally() }
        sandbox.destroy()
    }
}
