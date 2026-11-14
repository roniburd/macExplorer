import XCTest
import AppKit
@testable import UI
import Core
import MacxFS
import MacxFixtures
import MacxPluginKit

@MainActor
final class RemoteAddressBarTests: XCTestCase {
    private func loc(_ path: [String] = [], ref: String = "main") -> RemoteLocation {
        RemoteLocation(provider: "test.fake", repo: "demo", ref: ref, path: path)
    }

    private func harness() async throws -> (ShellHarness, BrowserWindowController) {
        let h = try await ShellHarness.make(self)
        _ = h.environment.remote.register([AddressResolverRemoteTestsFixture.demo()], source: "test")
        let controller = try await h.openWindow()
        return (h, controller)
    }

    func testTypingAProviderAddressOpensTheRemoteFolderAndRemembersIt() async throws {
        let (h, controller) = try await harness()
        await controller.addressBar.submitForTesting("fake:demo@main/src")
        try await h.waitUntil("remote folder loaded") {
            controller.session.folder.directory == self.loc(["src"]).url && controller.session.folder.state == .complete
        }
        XCTAssertEqual(ShellHarness.names(controller.session.folder).sorted(), ["a.swift", "lib"])
        XCTAssertEqual(h.environment.settings.recentRepositories.first,
                       RemoteLocation(provider: "test.fake", repo: "demo", ref: nil, path: []).url.absoluteString)
        XCTAssertEqual(h.environment.settings.recentLocations.first, loc(["src"]).url.absoluteString,
                       "no web URL from the fake provider: the remote URL is the recent text")
    }

    func testAFileAddressSelectsTheFileInItsFolder() async throws {
        let (h, controller) = try await harness()
        await controller.addressBar.submitForTesting("fake:demo/src/a.swift")
        try await h.waitUntil("parent loaded") {
            controller.session.folder.directory == self.loc(["src"]).url && controller.session.folder.state == .complete
        }
        try await h.waitUntil("a.swift selected") { controller.probeSelectedNames == ["a.swift"] }
    }

    func testEditingARemoteFolderShowsItsAddressNotAPath() async throws {
        let (h, controller) = try await harness()
        controller.session.navigate(to: loc(["src"]).url)
        try await h.waitUntil("remote loaded") { controller.session.folder.state == .complete }
        controller.focus(.addressBar)
        XCTAssertEqual(controller.addressBar.editField.stringValue, loc(["src"]).url.absoluteString)
    }

    func testAnUnknownRemoteShowsTheInlineError() async throws {
        let (_, controller) = try await harness()
        await controller.addressBar.submitForTesting("fake:demo/nope")
        XCTAssertEqual(controller.addressBar.errorText, "Can't find 'fake:demo/nope'")
        XCTAssertTrue(controller.addressBar.isEditing)
    }

    func testAMistypedRefShowsTheInlineErrorAndIsNotRemembered() async throws {
        let (h, controller) = try await harness()
        let before = (h.environment.settings.recentRepositories, h.environment.settings.recentLocations)
        await controller.addressBar.submitForTesting("fake:demo@nope")
        XCTAssertEqual(controller.addressBar.errorText, "Can't find 'fake:demo@nope'")
        XCTAssertTrue(controller.addressBar.isEditing)
        XCTAssertEqual(h.environment.settings.recentRepositories, before.0)
        XCTAssertEqual(h.environment.settings.recentLocations, before.1)
    }
}

/// The CoreTests fixture tree, duplicated here (UITests can't import CoreTests).
enum AddressResolverRemoteTestsFixture {
    static func demo() -> FakeRemoteProvider {
        FakeRemoteProvider(tree: ["main": [
            "": [RemoteItem(name: "src", kind: .directory), RemoteItem(name: "README.md", kind: .file, size: 3)],
            "src": [RemoteItem(name: "lib", kind: .directory), RemoteItem(name: "a.swift", kind: .file)],
            "src/lib": [],
        ], "dev": [
            "": [RemoteItem(name: "src", kind: .directory)],
            "src": [],
        ]])
    }
}
