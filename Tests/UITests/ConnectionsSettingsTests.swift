import XCTest
import AppKit
import SwiftUI
@testable import UI
@testable import Core
import MacxFixtures
import MacxPluginKit

@MainActor
final class ConnectionsSettingsTests: XCTestCase {
    func testRowsSayWhichProvidersAreBuiltInAndWhichComeFromPlugins() {
        let registry = ProviderRegistry(builtIns: [FakeRemoteProvider(id: "test.builtin", displayName: "Built")])
        _ = registry.register([FakeRemoteProvider(id: "test.plug", displayName: "Plugged")], source: "P.macxplugin")
        let plugin = LoadedPlugin(bundle: URL(filePath: "/x/P.macxplugin"), name: "P", version: "2.1", apiVersion: "1.0",
                                  providerIDs: ["test.plug"])
        let rows = ConnectionRows.rows(registry: registry, loaded: [plugin])
        XCTAssertEqual(rows.map(\.name), ["Built", "Plugged"])
        XCTAssertEqual(rows.map(\.status), [L10n.string("Built in"), String(format: L10n.string("Plugin %@ %@"), "P", "2.1")])
    }

    func testFailureTexts() {
        XCTAssertEqual(PluginFailureText.text(.apiMismatch("2.0")),
                       String(format: L10n.string("Built for plugin API %@ — this version needs %@"), "2.0", "1.x"))
        XCTAssertEqual(PluginFailureText.text(.apiMismatch(nil)),
                       String(format: L10n.string("Built for plugin API %@ — this version needs %@"), L10n.string("unknown"), "1.x"))
        XCTAssertEqual(PluginFailureText.text(.signatureMismatch), L10n.string("Not signed with macExplorer's certificate."))
        XCTAssertEqual(PluginFailureText.text(.duplicateProvider("a.b")),
                       String(format: L10n.string("Another provider already uses the id %@."), "a.b"))
        XCTAssertEqual(PluginFailureText.text(.invalidProviderID("a b")),
                       String(format: L10n.string("The provider id “%@” isn't valid: use letters, digits, “-” and “.” only."), "a b"))
    }

    func testPageRenders() throws {
        let sandbox = try Sandbox()
        addTeardownBlock { sandbox.destroy() }
        let env = CoreEnvironment.sandboxed(root: sandbox.root)
        let view = ConnectionsSettingsView(settings: env.settings, plugins: PluginsModel(environment: env), registry: env.remote,
                                           cache: env.remoteFiles, revealPlugins: {})
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }
}
