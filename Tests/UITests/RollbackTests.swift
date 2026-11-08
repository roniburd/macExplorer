import CryptoKit
import XCTest
@testable import UI
@testable import Core

// Install Previous Version…: UpdateController skip/reconcile, RollbackService staging, RollbackModel flow and the
// swap script. Every file touched lives in a temporary directory these tests create (and remove).

@MainActor
private final class InertEngine: UpdaterEngine {
    var automaticallyChecksForUpdates = true
    private(set) var checks = 0
    func start() throws {}
    func checkInBackground() { checks += 1 }
}

@MainActor
private func makeSettings() -> Core.Settings {
    Settings(storage: InMemorySettingsStorage(), home: URL(filePath: "/tmp/macx-tests-home", directoryHint: .isDirectory))
}

/// In-memory stand-in for Sparkle's `SUSkippedVersion` default.
@MainActor
private final class SkipBox: @unchecked Sendable {
    var value: Int?
    init(_ value: Int? = nil) { self.value = value }
    var skip: SparkleSkippedVersion {
        SparkleSkippedVersion(get: { [self] in value }, set: { [self] in value = $0 })
    }
}

@MainActor
final class UpdateControllerRollbackTests: XCTestCase {
    func testSkippedBuildsAreNotOfferedUntilAManualCheck() {
        let settings = makeSettings()
        settings.updateSkipThroughBuild = 214
        let model = UpdateModel(), engine = InertEngine()
        let c = UpdateController(model: model, settings: settings, engine: engine, installedVersion: "0.2.0-beta.13",
                                 installedBuild: 211, terminate: {})
        XCTAssertFalse(c.shouldProceed(version: "0.2.0-beta.15", build: 214))
        XCTAssertTrue(c.shouldProceed(version: "0.2.0-beta.16", build: 215))
        model.checkNow(userInitiated: false)
        XCTAssertEqual(settings.updateSkipThroughBuild, 214, "background checks keep the skip")
        model.checkNow()
        XCTAssertNil(settings.updateSkipThroughBuild, "Check for Updates… ends the skip")
        XCTAssertTrue(c.shouldProceed(version: "0.2.0-beta.15", build: 214))
        XCTAssertEqual(engine.checks, 2)
    }

    func testManualCheckClearsSparklesSkippedVersion() {
        let box = SkipBox(214)
        let model = UpdateModel()
        _ = UpdateController(model: model, settings: makeSettings(), engine: InertEngine(), installedVersion: "1",
                             installedBuild: 211, sparkleSkip: box.skip, terminate: {})
        model.checkNow(userInitiated: false)
        XCTAssertEqual(box.value, 214)
        model.checkNow()
        XCTAssertNil(box.value)
    }

    func testSkippedBuildOnBackgroundCheckReadsAsNoUpdate() {
        let settings = makeSettings()
        settings.updateSkipThroughBuild = 214
        let model = UpdateModel()
        let c = UpdateController(model: model, settings: settings, engine: InertEngine(), installedVersion: "0.2.0-beta.13",
                                 installedBuild: 211, terminate: {})
        model.checkNow(userInitiated: false)
        XCTAssertFalse(c.shouldProceed(version: "0.2.0-beta.15", build: 214))
        c.didAbort(UpdateFailure(UpdateController.suppressedError(version: "0.2.0-beta.15")))
        XCTAssertEqual(model.state, .idle)
    }

    func testLaunchAsTargetTurnsPendingIntoSkipAndTrashesBackup() {
        let settings = makeSettings()
        settings.pendingRollback = PendingRollback(targetBuild: 211, fromBuild: 214, backupPath: "/tmp/macx-none/Replaced-214.app")
        var trashed: [String] = []
        _ = UpdateController(model: UpdateModel(), settings: settings, engine: InertEngine(), installedVersion: "0.2.0-beta.13",
                             installedBuild: 211, trash: { trashed.append($0.path(percentEncoded: false)) }, terminate: {})
        XCTAssertEqual(settings.updateSkipThroughBuild, 214)
        XCTAssertNil(settings.pendingRollback)
        XCTAssertEqual(trashed, ["/tmp/macx-none/Replaced-214.app/"])
    }

    func testLaunchAsAnotherBuildDropsPendingWithoutSkip() {
        let settings = makeSettings()
        settings.pendingRollback = PendingRollback(targetBuild: 211, fromBuild: 214, backupPath: "/tmp/macx-none/Replaced-214.app")
        var trashed = 0
        _ = UpdateController(model: UpdateModel(), settings: settings, engine: InertEngine(), installedVersion: "0.2.0-beta.15",
                             installedBuild: 214, trash: { _ in trashed += 1 }, terminate: {})
        XCTAssertNil(settings.updateSkipThroughBuild)
        XCTAssertNil(settings.pendingRollback)
        XCTAssertEqual(trashed, 0)
    }

    func testUpdateInFlightWhileDownloadingOrReady() {
        let model = UpdateModel()
        let c = UpdateController(model: model, settings: makeSettings(), engine: InertEngine(), installedVersion: "1",
                                 installedBuild: 1, terminate: {})
        XCTAssertFalse(c.updateInFlight)
        model.send(.updateFound(version: "2"))
        XCTAssertTrue(c.updateInFlight)
        model.send(.readyToInstall(version: "2", notesURL: nil))
        XCTAssertTrue(c.updateInFlight)
    }

    func testMenuAvailabilityFollowsRollbackService() {
        let model = UpdateModel()
        _ = UpdateController(model: model, settings: makeSettings(), engine: InertEngine(), installedVersion: "1", terminate: {})
        XCTAssertTrue(model.isAvailable)
        XCTAssertFalse(model.canInstallPreviousVersion)
        XCTAssertFalse(UpdateModel().canInstallPreviousVersion)
    }
}

// MARK: RollbackService

@MainActor
private final class FakeTransport: RollbackTransport {
    var feed = Data()
    var archive = Data()
    var downloadError: (any Error)?
    let scratch: URL
    init(scratch: URL) { self.scratch = scratch }
    func data(from url: URL) async throws -> Data { feed }
    func download(_ url: URL, progress: @escaping @MainActor (Double?) -> Void) async throws -> URL {
        if let downloadError { throw downloadError }
        progress(0.5)
        let file = scratch.appending(path: "dl-\(UUID().uuidString).zip")
        try archive.write(to: file)
        progress(1)
        return file
    }
}

/// "Unzips" by creating MacExplorer.app with the given Info.plist values.
private struct FakeUnpacker: RollbackUnpacker {
    var bundleID = "com.macexplorer.app"
    var build = "204"
    func unzip(_ archive: URL, into directory: URL) async throws {
        let contents = directory.appending(path: "MacExplorer.app/Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleVersion": build]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"))
    }
}

private struct FakeCodeCheck: RollbackCodeCheck {
    var ok = true
    func signedLikeRunningApp(_ app: URL) -> Bool { ok }
}

private final class RecordingLauncher: RollbackLauncher {
    var launches: [(script: URL, arguments: [String])] = []
    func launch(script: URL, arguments: [String], log: URL) throws { launches.append((script, arguments)) }
}

@MainActor
final class RollbackServiceTests: XCTestCase {
    private var root: URL!
    private let key = Curve25519.Signing.PrivateKey()

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "macx-rollback-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root.appending(path: "Applications/MacExplorer.app"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "scratch"), withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func item(signing data: Data, build: Int = 204) -> AppcastItem {
        AppcastItem(version: "0.2.0", build: build, enclosureURL: URL(string: "https://example.invalid/a.zip")!,
                    edSignature: try! key.signature(for: data).base64EncodedString())
    }

    private func make(transport: FakeTransport? = nil, unpacker: FakeUnpacker = FakeUnpacker(), codeOK: Bool = true,
                      inFlight: Bool = false, settings: Core.Settings? = nil, launcher: RecordingLauncher = RecordingLauncher(),
                      skip: SparkleSkippedVersion = .inert,
                      quits: (() -> Void)? = nil) -> (RollbackService, FakeTransport, Core.Settings) {
        let t = transport ?? FakeTransport(scratch: root.appending(path: "scratch"))
        let s = settings ?? makeSettings()
        let config = RollbackService.Config(
            feedURL: URL(string: "https://example.invalid/appcast.xml")!,
            publicKey: key.publicKey.rawRepresentation.base64EncodedString(),
            appURL: root.appending(path: "Applications/MacExplorer.app", directoryHint: .isDirectory),
            bundleID: "com.macexplorer.app", installedVersion: "0.2.0-beta.15", installedBuild: 214, processID: 1,
            opener: "/usr/bin/true")
        let service = RollbackService(config: config, settings: s, updateInFlight: { inFlight }, transport: t,
                                      unpacker: unpacker, codeCheck: FakeCodeCheck(ok: codeOK), launcher: launcher,
                                      sparkleSkip: skip, terminate: { quits?() })
        return (service, t, s)
    }

    func testCandidatesComeFromTheFeed() async throws {
        let (service, transport, settings) = make()
        settings.updateChannel = .beta
        transport.feed = AppcastParserTests_fixture
        let items = try await service.candidates()
        XCTAssertEqual(items.map(\.build), [204])   // 214 is installed; 203/abc are dropped
    }

    func testPrepareStagesAVerifiedAppAndWillTerminateLaunchesTheSwap() async throws {
        let launcher = RecordingLauncher()
        let box = SkipBox()
        let (service, transport, settings) = make(launcher: launcher, skip: box.skip)
        transport.archive = Data("zip".utf8)
        let target = item(signing: transport.archive)
        defer { XCTAssertEqual(box.value, 214, "the older build's Sparkle skips through the build rolled back from") }
        var fractions: [Double?] = []
        let staged = try await service.prepare(target) { fractions.append($0) }
        XCTAssertEqual(fractions.compactMap { $0 }, [0.5, 1])
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.stagedApp.appending(path: "Contents/Info.plist").path(percentEncoded: false)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.directory.appending(path: "rollback.zip").path(percentEncoded: false)))
        service.arm(staged)
        service.willTerminate()
        XCTAssertEqual(settings.pendingRollback?.targetBuild, 204)
        XCTAssertEqual(settings.pendingRollback?.fromBuild, 214)
        XCTAssertEqual(launcher.launches.count, 1)
        XCTAssertEqual(launcher.launches.first?.arguments.first, "1")
        XCTAssertEqual(launcher.launches.first?.arguments.last, "/usr/bin/true")
        try? FileManager.default.removeItem(at: staged.directory)
    }

    func testDisarmedServiceDoesNothingAtQuit() async throws {
        let launcher = RecordingLauncher()
        let box = SkipBox()
        let (service, transport, settings) = make(launcher: launcher, skip: box.skip)
        transport.archive = Data("zip".utf8)
        let staged = try await service.prepare(item(signing: transport.archive)) { _ in }
        service.arm(staged)
        service.disarm()
        service.willTerminate()
        XCTAssertNil(settings.pendingRollback)
        XCTAssertNil(box.value)
        XCTAssertTrue(launcher.launches.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.directory.path(percentEncoded: false)))
    }

    func testBadSignatureIsRejected() async {
        let (service, transport, _) = make()
        transport.archive = Data("zip".utf8)
        let forged = item(signing: Data("something else".utf8))
        await assertThrows(.badSignature) { _ = try await service.prepare(forged) { _ in } }
    }

    func testWrongBuildBundleOrSignatureIsRejected() async {
        for (unpacker, codeOK, expected) in [
            (FakeUnpacker(build: "205"), true, RollbackError.wrongApp(L10n.string("build number"))),
            (FakeUnpacker(bundleID: "com.example.other"), true, .wrongApp(L10n.string("bundle identifier"))),
            (FakeUnpacker(), false, .wrongApp(L10n.string("code signature"))),
        ] {
            let (service, transport, _) = make(unpacker: unpacker, codeOK: codeOK)
            transport.archive = Data("zip".utf8)
            let target = item(signing: transport.archive)
            await assertThrows(expected) { _ = try await service.prepare(target) { _ in } }
        }
    }

    func testPendingUpdateBlocksRollback() async {
        let (service, transport, _) = make(inFlight: true)
        XCTAssertEqual(service.preflight(), .updatePending)
        transport.archive = Data("zip".utf8)
        let target = item(signing: transport.archive)
        await assertThrows(.updatePending) { _ = try await service.prepare(target) { _ in } }
    }

    func testDownloadFailureIsANetworkError() async {
        let (service, transport, _) = make()
        transport.downloadError = URLError(.notConnectedToInternet)
        let target = item(signing: Data())
        do {
            _ = try await service.prepare(target) { _ in }
            XCTFail("expected a network error")
        } catch {
            guard case .network = error else { return XCTFail("got \(error)") }
        }
    }

    private func assertThrows(_ expected: RollbackError, _ body: () async throws -> Void,
                              file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? RollbackError, expected, file: file, line: line)
        }
    }
}

/// The CoreTests fixture can't be imported across test targets; the same items, enough for the service.
private let AppcastParserTests_fixture = Data("""
<?xml version='1.0' encoding='utf-8'?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel>
<item><sparkle:version>214</sparkle:version><sparkle:shortVersionString>0.2.0-beta.15</sparkle:shortVersionString>
<sparkle:channel>beta</sparkle:channel><enclosure url="https://example.invalid/215.zip" sparkle:edSignature="eA==" /></item>
<item><sparkle:version>204</sparkle:version><sparkle:shortVersionString>0.2.0</sparkle:shortVersionString>
<enclosure url="https://example.invalid/204.zip" sparkle:edSignature="eA==" /></item>
<item><sparkle:version>203</sparkle:version><enclosure url="https://example.invalid/203.zip" /></item>
<item><sparkle:version>170</sparkle:version><enclosure url="https://example.invalid/170.zip" sparkle:edSignature="eA==" /></item>
</channel></rss>
""".utf8)

// MARK: RollbackModel

@MainActor
private final class FakeRollbackService: RollbackServicing {
    var installedVersion = "0.2.0-beta.15"
    var blocked: RollbackError?
    var items: [AppcastItem] = []
    var prepareError: RollbackError?
    private(set) var armed: StagedRollback?
    private(set) var quits = 0, disarms = 0
    func preflight() -> RollbackError? { blocked }
    func candidates() async throws(RollbackError) -> [AppcastItem] { items }
    func prepare(_ item: AppcastItem, progress: @escaping @MainActor (Double?) -> Void) async throws(RollbackError) -> StagedRollback {
        progress(0.25)
        if let prepareError { throw prepareError }
        let dir = URL(filePath: "/tmp/macx-none", directoryHint: .isDirectory)
        return StagedRollback(item: item, stagedApp: dir.appending(path: "MacExplorer.app"), backup: dir.appending(path: "b.app"), directory: dir)
    }
    func arm(_ staged: StagedRollback) { armed = staged }
    func disarm() { armed = nil; disarms += 1 }
    func quit() { quits += 1 }
}

@MainActor
final class RollbackModelTests: XCTestCase {
    private let a = AppcastItem(version: "0.2.0-beta.13", build: 211, enclosureURL: URL(string: "https://example.invalid/a")!, edSignature: "s")
    private let b = AppcastItem(version: "0.2.0-beta.11", build: 204, enclosureURL: URL(string: "https://example.invalid/b")!, edSignature: "s")

    func testLoadSelectsNewestAndInstallArmsThenQuits() async {
        let service = FakeRollbackService()
        service.items = [a, b]
        let model = RollbackModel(service: service)
        await model.load()
        XCTAssertEqual(model.phase, .list)
        XCTAssertEqual(model.selectedItem, a)
        await model.install(b)
        XCTAssertEqual(model.phase, .ready(b))
        XCTAssertEqual(service.armed?.item, b)
        XCTAssertEqual(service.quits, 1)
        model.quitNow()
        XCTAssertEqual(service.quits, 2)
        model.cancelInstall()
        XCTAssertEqual(model.phase, .list)
        XCTAssertNil(service.armed)
    }

    func testEmptyBlockedAndFailedStates() async {
        let service = FakeRollbackService()
        let model = RollbackModel(service: service)
        await model.load()
        XCTAssertEqual(model.phase, .empty)
        service.blocked = .updatePending
        await model.load()
        XCTAssertEqual(model.phase, .failed(RollbackError.updatePending.message))
        service.blocked = nil
        service.items = [a]
        await model.load()
        service.prepareError = .badSignature
        await model.install(a)
        XCTAssertEqual(model.phase, .failed(RollbackError.badSignature.message))
        XCTAssertEqual(service.quits, 0)
        XCTAssertNil(service.armed)
    }
}

// MARK: swap script

final class RollbackSwapTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "macx-swap-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func bundle(_ name: String, marker: String) throws -> URL {
        let url = root.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(marker.utf8).write(to: url.appending(path: "marker"))
        return url
    }

    private func marker(_ url: URL) -> String? {
        (try? Data(contentsOf: url.appending(path: "marker"))).map { String(decoding: $0, as: UTF8.self) }
    }

    /// A PID that has already exited (the helper's wait loop ends at once).
    private func exitedPID() throws -> Int32 {
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/true")
        try p.run()
        p.waitUntilExit()
        return p.processIdentifier
    }

    private func run(app: URL, staged: URL, backup: URL) throws -> (status: Int32, opened: String) {
        let script = root.appending(path: "swap.sh")
        try Data(RollbackSwap.script.utf8).write(to: script)
        let opened = root.appending(path: "opened.txt")
        // The "opener" records what would have been reopened instead of launching anything.
        let opener = root.appending(path: "opener.sh")
        try Data("#!/bin/sh\necho \"$1\" > '\(opened.path(percentEncoded: false))'\n".utf8).write(to: opener)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: opener.path(percentEncoded: false))
        let p = Process()
        p.executableURL = URL(filePath: "/bin/sh")
        p.arguments = [script.path(percentEncoded: false)] + RollbackSwap.arguments(
            pid: try exitedPID(), app: app, staged: staged, backup: backup, opener: opener.path(percentEncoded: false))
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        let text = (try? String(contentsOf: opened, encoding: .utf8)) ?? ""
        return (p.terminationStatus, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testSwapReplacesTheAppKeepsABackupAndReopens() throws {
        let app = try bundle("Apps/MacExplorer.app", marker: "new-version-214")
        let staged = try bundle("Stage/MacExplorer.app", marker: "old-version-204")
        let backup = root.appending(path: "Stage/Replaced-214.app", directoryHint: .isDirectory)
        let result = try run(app: app, staged: staged, backup: backup)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(marker(app), "old-version-204")
        XCTAssertEqual(marker(backup), "new-version-214")
        XCTAssertEqual(result.opened, app.path(percentEncoded: false))
    }

    func testMissingStagedAppRestoresTheOriginal() throws {
        let app = try bundle("Apps/MacExplorer.app", marker: "new-version-214")
        let staged = root.appending(path: "Stage/Missing.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root.appending(path: "Stage"), withIntermediateDirectories: true)
        let backup = root.appending(path: "Stage/Replaced-214.app", directoryHint: .isDirectory)
        let result = try run(app: app, staged: staged, backup: backup)
        XCTAssertEqual(result.status, 3)
        XCTAssertEqual(marker(app), "new-version-214")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path(percentEncoded: false)))
        XCTAssertEqual(result.opened, app.path(percentEncoded: false))
    }
}
