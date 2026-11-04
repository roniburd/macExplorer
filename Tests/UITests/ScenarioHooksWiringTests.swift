import AppKit
import XCTest
import Core
import MacxFixtures
@testable import UI

@MainActor
final class ScenarioHooksWiringTests: XCTestCase {
    func testBrowserWindowInstallsEveryScenarioHook() throws {
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("needs a GUI session") }
        let sandbox = try Sandbox(prefix: "macx-tests")
        defer { sandbox.destroy() }
        let root = try sandbox.createDirectory("macx-scenario-root")
        var options = LaunchOptions()
        options.root = root
        options.stateDirectory = try sandbox.createDirectory("state")
        let context = UIContext(environment: CoreEnvironment.sandboxed(root: sandbox.root), options: options)
        let window = context.windows.openWindow(at: root)
        defer { window.close() }
        let hooks = window.scenarioHooks
        XCTAssertNotNil(hooks.addressText, "P1-27")
        XCTAssertNotNil(hooks.isEditingAddress, "P1-27")
        XCTAssertNotNil(hooks.emptyStateText, "P1-33")
        XCTAssertNotNil(hooks.bannerText, "P1-33")
        XCTAssertNotNil(hooks.renameText, "P1-34")
        XCTAssertNotNil(hooks.performDrop, "P1-36")
        XCTAssertTrue(NSClassFromString("MacxApplication") == MacxApplication.self, "@objc name used by Info.plist")
    }
}
