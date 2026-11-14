import XCTest
import AppKit
@testable import UI
import Core
import MacxFixtures
import MacxPluginKit

/// The launch's plugin load (spec §5.3): when it is skipped, that it runs once, and what windows do once it is done.
/// Sandbox files only; no plugin code is loaded (an empty `--plugins-dir`, fake providers).
@MainActor
final class PluginsModelTests: XCTestCase {
    func testASandboxedRunWithoutAPluginsDirNeverLoadsTheRealFolder() async throws {
        let h = try await ShellHarness.make(self)
        await h.context.plugins.load(options: h.context.options, optionKeyHeld: false)
        XCTAssertEqual(h.context.plugins.skipped, .sandboxed)
        XCTAssertTrue(h.context.plugins.didLoad)
        XCTAssertTrue(h.context.plugins.isFinished)
        XCTAssertEqual(h.context.plugins.loaded, [])
    }

    func testTheSettingAndTheOptionKeySkipLoading() async throws {
        let disabled = try await ShellHarness.make(self)
        disabled.environment.settings.pluginsDisabled = true
        await disabled.context.plugins.load(options: disabled.context.options, optionKeyHeld: true)
        XCTAssertEqual(disabled.context.plugins.skipped, .disabledInSettings, "the setting is checked first")

        let option = try await ShellHarness.make(self)
        await option.context.plugins.load(options: option.context.options, optionKeyHeld: true)
        XCTAssertEqual(option.context.plugins.skipped, .optionKey)
    }

    func testAnEmptyPluginsDirLoadsNothingAndLoadRunsOnce() async throws {
        let h = try await ShellHarness.make(self)
        var options = h.context.options
        options.pluginsDirectory = try h.sandbox.createDirectory("plugins")
        await h.context.plugins.load(options: options, optionKeyHeld: false)
        XCTAssertNil(h.context.plugins.skipped)
        XCTAssertEqual(h.context.plugins.failures, [])
        XCTAssertEqual(h.context.plugins.loaded, [])
        await h.context.plugins.load(options: options, optionKeyHeld: true)
        XCTAssertNil(h.context.plugins.skipped, "a second call does nothing")
    }

    func testAWindowOnALateProviderReadsAgainOnceItsPluginLoads() async throws {
        try ShellHarness.requireWindowServer()
        let h = try await ShellHarness.make(self)
        let url = RemoteLocation(provider: "test.late", repo: "o/r", ref: "main").url
        let controller = h.context.windows.openWindow(at: url)
        try await h.waitUntil("not found before the provider exists") {
            if case .error = controller.session.folder.state { return true } else { return false }
        }
        let late = FakeRemoteProvider(id: "test.late", displayName: "Late")
        late.setTree(repo: "o/r", ["": [RemoteItem(name: "a.txt", kind: .file, size: 1)]])
        h.environment.remote.register([late], source: "Late.macxplugin")
        h.context.windows.pluginsDidLoad(providerIDs: ["test.late"])
        try await h.waitUntil("listed once the plugin loaded") { controller.session.folder.state == .complete }
        XCTAssertNotNil(controller.session.folder.row(named: "a.txt"))
    }
}
