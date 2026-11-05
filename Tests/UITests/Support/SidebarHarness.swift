import XCTest
import AppKit
import Synchronization
@testable import UI
@testable import Core
import MacxFS
import MacxFixtures

/// Volumes that live inside the sandbox: "Macintosh HD" at `<sandbox>/boot` (boot, internal) and "USB" at
/// `<sandbox>/usb` (external, ejectable). The sidebar's Locations and Folders roots come only from here, so no test
/// lists, watches or resolves anything outside its sandbox.
final class SandboxVolumeScanner: VolumeScanning {
    let volumes: Mutex<[VolumeInfo]>
    init(_ volumes: [VolumeInfo]) { self.volumes = Mutex(volumes) }
    func scan() throws -> [VolumeInfo] { volumes.withLock { $0 } }
    func availableCapacity(of mountPoint: URL) -> Int64? { nil }
    func set(_ v: [VolumeInfo]) { volumes.withLock { $0 = v } }

    static func volume(_ id: String, name: String, at url: URL, boot: Bool, local: Bool = true) -> VolumeInfo {
        VolumeInfo(id: VolumeID(raw: id), mountPoint: url, name: name, format: "APFS", isBoot: boot, isInternal: boot,
                   isRemovable: !boot, isEjectable: !boot, isLocal: local, isReadOnly: false, isBrowsable: true,
                   totalCapacity: 1_000_000,
                   capabilities: VolumeCapabilities(idStable: true, renameExcl: true, clone: true, caseSensitive: false))
    }
}

/// Records eject attempts; answers from `result`.
final class RecordingEjector: Ejecting {
    private let state = Mutex<(ejected: [String], result: EjectError?)>(([], nil))
    var ejected: [String] { state.withLock { $0.ejected } }
    func fail(with error: EjectError?) { state.withLock { $0.result = error } }
    func eject(_ mountPoint: URL) async throws(EjectError) {
        let result = state.withLock { s -> EjectError? in
            s.ejected.append(mountPoint.lastPathComponent)
            return s.result
        }
        if let result { throw result }
    }
    func blockingProcesses(_ mountPoint: URL, timeout: Duration) async -> [String] { [] }
    func onlyOwnProcessHolds(_ mountPoint: URL, timeout: Duration) async -> Bool { false }
}

@MainActor
final class ScriptedEjectPrompts: EjectPrompting {
    var choice: RunningJobsChoice = .wait
    private(set) var asked: [(String, Int)] = []
    private(set) var failures: [(String, EjectError)] = []
    func runningJobs(volumeName: String, count: Int, window: NSWindow?) async -> RunningJobsChoice {
        asked.append((volumeName, count))
        return choice
    }
    func ejectFailed(volumeName: String, error: EjectError, window: NSWindow?) async { failures.append((volumeName, error)) }
}

/// A CommandHandler that records what reaches it (and can say yes to everything).
@MainActor
final class SidebarRecordingHandler: CommandHandler {
    private(set) var performed: [(Command, CommandTarget)] = []
    func canPerform(_ command: Command, target: CommandTarget) -> Bool { true }
    func perform(_ command: Command, target: CommandTarget, sender: Any?) { performed.append((command, target)) }
}

/// One sidebar on a session, with the sandbox volumes above. `home` is `<sandbox>/boot/home` (default favorites);
/// Applications is hidden so its default (/Applications) is never resolved.
@MainActor
final class SidebarHarness {
    let sandbox: Sandbox
    let boot: URL
    let usb: URL
    let home: URL
    let scanner: SandboxVolumeScanner
    let ejector = RecordingEjector()
    let prompts = ScriptedEjectPrompts()
    let environment: CoreEnvironment
    let context: UIContext
    private(set) var session: BrowserSession!
    private(set) var sidebar: SidebarViewController!

    var settings: Settings { environment.settings }

    /// `root`: a --root (relative to boot) for sandbox-mode sidebars.
    static func make(_ testCase: XCTestCase, folder: String = "home", root: String? = nil,
                     prepare: (SidebarHarness) throws -> Void = { _ in }) async throws -> SidebarHarness {
        let h = try SidebarHarness(root: root)
        testCase.addTeardownBlock { @MainActor in await h.tearDown() }
        try prepare(h)
        _ = await h.environment.start()
        h.session = BrowserSession(environment: h.environment, initialURL: h.url(folder))
        h.sidebar = SidebarViewController(context: h.context, session: h.session)
        _ = h.sidebar.view
        await h.settle()
        return h
    }

    private init(root: String?) throws {
        _ = NSApplication.shared
        sandbox = try Sandbox(prefix: "macx-tests")
        boot = try sandbox.createDirectory("boot")
        usb = try sandbox.createDirectory("usb")
        home = try sandbox.createDirectory("boot/home")
        scanner = SandboxVolumeScanner([
            SandboxVolumeScanner.volume("uuid:boot", name: "Macintosh HD", at: boot, boot: true),
            SandboxVolumeScanner.volume("uuid:usb", name: "USB", at: usb, boot: false),
        ])
        let lanes = LanePool()
        environment = CoreEnvironment(
            statePaths: StatePaths(root: sandbox.root.appending(path: "state", directoryHint: .isDirectory)),
            lanes: lanes, settingsStorage: InMemorySettingsStorage(), volumeScanner: scanner, volumeEvents: nil,
            pasteboard: InMemoryPasteboard(), launchServices: FakeLaunchServices(), ejector: ejector,
            trash: SandboxTrash(directory: sandbox.root.appending(path: ".trash", directoryHint: .isDirectory)),
            home: home)
        environment.settings.hiddenDefaultFavorites = [.applications]
        var options = LaunchOptions()
        // No --root: the tree's roots are the (sandbox) volumes; SidebarSandboxRootTests covers --root.
        options.stateDirectory = sandbox.root.appending(path: "state", directoryHint: .isDirectory)
        options.sandboxTrash = sandbox.root.appending(path: ".trash", directoryHint: .isDirectory)
        options.pasteboardName = "macx-tests-\(UUID().uuidString)"
        options.fakeLaunchServices = true
        options.skipOnboarding = true
        let bootURL = boot
        options.root = root.map { bootURL.appending(path: $0, directoryHint: .isDirectory) }
        context = UIContext(environment: environment, options: options)
        context.installInteraction(ScriptedInteraction())
        context.ejectPrompts = prompts
    }

    func url(_ relative: String) -> URL {
        relative.isEmpty ? boot : boot.appending(path: relative, directoryHint: .isDirectory)
    }

    @discardableResult func dir(_ relative: String) throws -> URL { try sandbox.createDirectory("boot/" + relative) }
    @discardableResult func file(_ relative: String) throws -> URL { try sandbox.createFile("boot/" + relative) }

    /// Favorites resolved, reveal done, pending main-actor work run.
    func settle() async {
        for _ in 0..<3 {
            await sidebar.favorites.settled()
            await sidebar.revealSettled()
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func waitUntil(_ what: String, timeout: Duration = .seconds(30), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { throw ShellHarnessError.timeout(what) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: outline queries

    var outline: SidebarOutlineView { sidebar.outlineView }

    func rows(in section: SidebarSection) -> [SidebarItem] {
        (0..<outline.numberOfRows).compactMap { sidebar.item(atRow: $0) }.filter { !$0.isHeader && $0.section == section }
    }

    func names(in section: SidebarSection) -> [String] { rows(in: section).map(Self.title) }

    func row(named name: String, in section: SidebarSection) -> Int {
        (0..<outline.numberOfRows).first {
            guard let item = sidebar.item(atRow: $0), !item.isHeader, item.section == section else { return false }
            return Self.title(item) == name
        } ?? -1
    }

    func cell(atRow row: Int) -> SidebarCellView? {
        outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCellView
    }

    static func title(_ item: SidebarItem) -> String {
        switch item {
        case .favorite(let f): f.name
        case .location(let v): v.name
        case .iCloudDrive: "iCloud Drive"
        case .cloudStorage(let folder): folder.name
        case .trash: "Trash"
        case .folder(let node): node.name
        case .favoritesHeader: "FAVORITES"
        case .locationsHeader: "LOCATIONS"
        case .foldersHeader: "FOLDERS"
        }
    }

    func tearDown() async {
        sidebar = nil
        session?.close()
        await environment.fileOps.waitUntilIdle()
        if let name = context.options.pasteboardName { NSPasteboard(name: NSPasteboard.Name(name)).releaseGlobally() }
        sandbox.destroy()
    }
}
