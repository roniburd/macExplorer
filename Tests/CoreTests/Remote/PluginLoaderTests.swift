@testable import Core
import Foundation
import MacxFixtures
import MacxPluginKit
import XCTest

/// Fake bundle code: the principal class comes from a table keyed by bundle name; nothing is dlopen'ed.
struct FakeBundleLoader: PluginBundleLoading {
    let classes: [String: MacxPlugin.Type]
    func principalClass(of bundle: URL) throws(PluginLoadFailure.Reason) -> MacxPlugin.Type {
        guard let type = classes[bundle.deletingPathExtension().lastPathComponent] else { throw .missingPrincipalClass }
        return type
    }
}
struct FixedCodeCheck: PluginCodeCheck {
    let rejected: Set<String>
    func signedLikeApp(_ bundle: URL) -> Bool { !rejected.contains(bundle.deletingPathExtension().lastPathComponent) }
}

/// Records the order of checks and loads; the code identity of a bundle changes once it has been loaded when the
/// bundle is in `swappedOnLoad` (someone replaced it on disk between the check and the load).
final class CheckLoadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [String] = []
    private var loadedNames: Set<String> = []
    var events: [String] { lock.withLock { _events } }
    func record(_ event: String, loaded name: String? = nil) {
        lock.withLock { _events.append(event); if let name { loadedNames.insert(name) } }
    }
    func wasLoaded(_ name: String) -> Bool { lock.withLock { loadedNames.contains(name) } }
}
struct LoggingCodeCheck: PluginCodeCheck {
    let log: CheckLoadLog
    let swappedOnLoad: Set<String>
    func signedLikeApp(_ bundle: URL) -> Bool { codeIdentity(bundle) != nil }
    func codeIdentity(_ bundle: URL) -> Data? {
        let name = bundle.deletingPathExtension().lastPathComponent
        log.record("check \(name)")
        return Data((swappedOnLoad.contains(name) && log.wasLoaded(name) ? "swapped" : "original").utf8)
    }
}
struct LoggingBundleLoader: PluginBundleLoading {
    let log: CheckLoadLog
    let inner: FakeBundleLoader
    func principalClass(of bundle: URL) throws(PluginLoadFailure.Reason) -> MacxPlugin.Type {
        let name = bundle.deletingPathExtension().lastPathComponent
        log.record("load \(name)", loaded: name)
        return try inner.principalClass(of: bundle)
    }
}

final class GoodPlugin: MacxPlugin {
    override func makeProviders() -> [any RemoteProvider] { [FakeRemoteProvider(id: "test.good", displayName: "Good")] }
}
final class DuplicatePlugin: MacxPlugin {
    override func makeProviders() -> [any RemoteProvider] { [FakeRemoteProvider(id: "test.builtin")] }
}

@MainActor
final class PluginLoaderTests: XCTestCase {
    var sandbox: Sandbox!
    var dir: URL!

    override func setUp() async throws {
        sandbox = try Sandbox()
        let s = sandbox!
        addTeardownBlock { s.destroy() }
        dir = try sandbox.createDirectory("Plugins")
    }

    /// <name>.macxplugin/Contents/Info.plist with the given API version (nil = key absent).
    private func bundle(_ name: String, api: String?, version: String = "1.2") throws {
        var plist: [String: Any] = ["CFBundleName": name, "CFBundleShortVersionString": version, "NSPrincipalClass": name]
        if let api { plist[MacxPluginAPI.infoPlistKey] = api }
        let contents = dir.appending(path: "\(name).macxplugin/Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appending(path: "Info.plist"))
    }

    private func loader(rejected: Set<String> = [], classes: [String: MacxPlugin.Type]) -> PluginLoader {
        PluginLoader(directory: dir, codeCheck: FixedCodeCheck(rejected: rejected), bundleLoader: FakeBundleLoader(classes: classes))
    }

    func testLoadsACompatibleSignedPluginAndRegistersItsProviders() async throws {
        try bundle("Good", api: "1.3")
        let registry = ProviderRegistry(builtIns: [])
        let l = loader(classes: ["Good": GoodPlugin.self])
        let failures = await l.loadAll(into: registry)
        XCTAssertEqual(failures, [])
        XCTAssertEqual(l.loaded.map(\.name), ["Good"])
        XCTAssertEqual(l.loaded.first?.providerIDs, ["test.good"])
        XCTAssertEqual(l.loaded.first?.version, "1.2")
        XCTAssertNotNil(registry.provider(id: "test.good"))
    }

    func testEachBadBundleIsSkippedWithItsReason() async throws {
        try bundle("Old", api: "2.0")
        try bundle("NoKey", api: nil)
        try bundle("Unsigned", api: "1.0")
        try bundle("NoClass", api: "1.0")
        try bundle("Dup", api: "1.0")
        try FileManager.default.createDirectory(at: dir.appending(path: "ignored.bundle"), withIntermediateDirectories: true)
        let registry = ProviderRegistry(builtIns: [FakeRemoteProvider(id: "test.builtin")])
        let l = loader(rejected: ["Unsigned"], classes: ["Unsigned": GoodPlugin.self, "Dup": DuplicatePlugin.self])
        let failures = await l.loadAll(into: registry)
        XCTAssertEqual(Set(failures.map { "\($0.bundle.deletingPathExtension().lastPathComponent):\($0.reason)" }), [
            "Dup:duplicateProvider(\"test.builtin\")", "NoClass:missingPrincipalClass", "NoKey:apiMismatch(nil)",
            "Old:apiMismatch(Optional(\"2.0\"))", "Unsigned:signatureMismatch",
        ])
        XCTAssertEqual(l.loaded.map(\.name), [], "Dup registered nothing, so it isn't listed as loaded")
        XCTAssertEqual(registry.providers.map(\.id), ["test.builtin"])
    }

    func testEachBundleIsCheckedRightBeforeAndAfterItsOwnLoad() async throws {
        try bundle("A", api: "1.0")
        try bundle("B", api: "1.0")
        let log = CheckLoadLog()
        let l = PluginLoader(directory: dir, codeCheck: LoggingCodeCheck(log: log, swappedOnLoad: []),
                             bundleLoader: LoggingBundleLoader(log: log, inner: FakeBundleLoader(classes: ["A": GoodPlugin.self, "B": DuplicatePlugin.self])))
        _ = await l.loadAll(into: ProviderRegistry(builtIns: []))
        XCTAssertEqual(log.events, ["check A", "load A", "check A", "check B", "load B", "check B"])
    }

    func testABundleSwappedBetweenTheCheckAndTheLoadIsRefused() async throws {
        try bundle("Swapped", api: "1.0")
        try bundle("Good", api: "1.0")
        let log = CheckLoadLog()
        let registry = ProviderRegistry(builtIns: [])
        let l = PluginLoader(directory: dir, codeCheck: LoggingCodeCheck(log: log, swappedOnLoad: ["Swapped"]),
                             bundleLoader: LoggingBundleLoader(log: log, inner: FakeBundleLoader(classes: ["Swapped": DuplicatePlugin.self, "Good": GoodPlugin.self])))
        let failures = await l.loadAll(into: registry)
        XCTAssertEqual(failures.map(\.reason), [.signatureMismatch])
        XCTAssertEqual(failures.first?.bundle.lastPathComponent, "Swapped.macxplugin")
        XCTAssertEqual(registry.providers.map(\.id), ["test.good"], "the swapped plugin's providers were never registered")
        XCTAssertEqual(l.loaded.map(\.name), ["Good"])
    }

    func testMissingDirectoryIsNotAnError() async {
        let l = PluginLoader(directory: sandbox.url("none"), codeCheck: FixedCodeCheck(rejected: []))
        let failures = await l.loadAll(into: ProviderRegistry(builtIns: []))
        XCTAssertEqual(failures, [])
    }

    func testSecCodeCheckRejectsAnUnsignedBundle() throws {
        try bundle("Plain", api: "1.0")
        XCTAssertFalse(SecCodePluginCheck().signedLikeApp(dir.appending(path: "Plain.macxplugin")))
        XCTAssertFalse(SecCodePluginCheck.hasCertificate(dir.appending(path: "Plain.macxplugin")))
    }
}
