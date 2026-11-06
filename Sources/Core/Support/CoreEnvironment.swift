import Foundation
import MacxFS

/// Every Core service, wired once per app (or per test/scenario sandbox). §3.12.
@MainActor
public final class CoreEnvironment {
    public let statePaths: StatePaths
    public let lanes: LanePool
    public let types: TypeRegistry
    public let readers: DirectoryReaders
    public let volumes: Volumes
    public let settings: Settings
    /// Per-folder view choices (P2-07 + design 2026-11-05 §2), in the same storage as `settings`.
    public let folderViews: FolderViewStore
    public let changeBus: ChangeBus
    /// On-demand folder sizes (P2-13): shared cache, one session per folder view with sizes on.
    public let folderSizes: FolderSizeService
    /// uid → user name for the Owner column (P2-15), shared by every folder.
    public let ownerNames = OwnerNameCache()
    public let clipboard: Clipboard
    public let launchServices: LaunchServicesCache
    public let ejectCoordinator: EjectCoordinator
    public let journal: Journal
    public let trash: any TrashService
    public let interaction: InteractionProxy
    public let fileOps: FileOpQueue
    public let undo: FileOpUndoStack
    public let operations: OperationsCenter
    public let termination: TerminationCoordinator

    /// Undo action names ("Copy", "Move"…) are user-visible text, which Core never produces: the app installs a
    /// localized formatter at launch (P1-26). Default: the verb's raw value ("copying").
    public var undoActionName: @MainActor (JobDescription) -> String {
        get { actionNamer.format }
        set { actionNamer.format = newValue }
    }

    @MainActor final class ActionNamer {
        var format: @MainActor (JobDescription) -> String = { $0.verb.rawValue }
    }

    /// §4.2: called by the volume release path with the jobs still running on the released volume (queued ones are
    /// paused). The UI (P1-28 eject, P1-38 InteractionRouter) installs it and asks the user to cancel or wait.
    public var onRunningJobsOnReleasedVolume: (@MainActor (VolumeID, [JobID]) async -> Void)?

    private let actionNamer: ActionNamer
    private var tokens: [ObserverToken] = []
    private var startTask: Task<RecoveryReport, Never>?

    public convenience init(statePaths: StatePaths, lanes: LanePool, settingsStorage: any SettingsStorage,
                            volumeScanner: any VolumeScanning, volumeEvents: (any VolumeEventSource)?,
                            pasteboard: any PasteboardBackend, launchServices: any LaunchServicesProviding,
                            ejector: any Ejecting, trash: any TrashService, fileOpTuning: FileOpTuning = FileOpTuning(),
                            home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        // `home` (additive, consistency pass): the app passes its --root in sandbox mode (P1-26 AppBootstrap) so
        // default favorites and "go home" fallbacks never leave the sandbox.
        self.init(statePaths: statePaths, lanes: lanes, settingsStorage: settingsStorage, volumeScanner: volumeScanner,
                  volumeEvents: volumeEvents, pasteboard: pasteboard, launchServices: launchServices, ejector: ejector,
                  trash: trash, fileOpTuning: fileOpTuning, home: home,
                  interactionTarget: nil)
    }

    init(statePaths: StatePaths, lanes: LanePool, settingsStorage: any SettingsStorage,
         volumeScanner: any VolumeScanning, volumeEvents: (any VolumeEventSource)?,
         pasteboard: any PasteboardBackend, launchServices provider: any LaunchServicesProviding,
         ejector: any Ejecting, trash: any TrashService, fileOpTuning: FileOpTuning,
         home: URL, interactionTarget: (any FileOpInteraction)?) {
        self.statePaths = statePaths
        self.lanes = lanes
        self.types = .shared
        let volumes = Volumes(lanes: lanes, scanner: volumeScanner, events: volumeEvents)
        self.volumes = volumes
        let readers = DirectoryReaders(lanes: lanes, mountTable: volumes.mountTableStore, types: .shared)
        self.readers = readers
        self.settings = Settings(storage: settingsStorage, home: home)
        // Imports the earlier path-keyed folder-views.json once (the file is left in place).
        let legacyFolderViews = statePaths.folderViewsFile
        self.folderViews = FolderViewStore(storage: settingsStorage, legacyJSON: { try? Data(contentsOf: legacyFolderViews) })
        let bus = ChangeBus()
        self.changeBus = bus
        self.folderSizes = FolderSizeService(lanes: lanes, mountTable: volumes.mountTableStore, changeBus: bus,
                                             makeSubtreeWatcher: { url, handler in SubtreeWatcher(directory: url, handler: handler) })
        self.clipboard = Clipboard(backend: pasteboard)
        self.launchServices = LaunchServicesCache(provider: provider, types: .shared)
        self.ejectCoordinator = EjectCoordinator(volumes: volumes, ejector: ejector)
        let journal = Journal(fileURL: statePaths.journal)
        self.journal = journal
        self.trash = trash
        let interaction = InteractionProxy()
        if let interactionTarget { interaction.setTarget(interactionTarget) }
        self.interaction = interaction
        let queue = FileOpQueue(lanes: lanes, trash: trash, journal: journal, interaction: interaction,
                                tuning: fileOpTuning, startsHeld: true)
        self.fileOps = queue
        let undo = FileOpUndoStack(queue: queue)
        self.undo = undo
        let namer = ActionNamer()
        self.actionNamer = namer
        let operations = OperationsCenter(queue: queue, undo: undo, changeBus: bus, actionName: { namer.format($0) })
        self.operations = operations
        self.termination = TerminationCoordinator(queue: queue, operations: operations)

        // §4.2 release (S1 contract note 15): cancel this volume's reads first, then pause the jobs touching it.
        // Watchers stop through FolderModel's volume-gone path (P1-11); windows move home in WindowManager (P1-26).
        // Running jobs go to onRunningJobsOnReleasedVolume (the UI asks cancel/wait).
        tokens.append(volumes.addReleaseHandler { [weak self, weak volumes] id in
            await readers.cancelAll(on: id)
            if let mountPoint = volumes?.list.first(where: { $0.id == id })?.mountPoint {
                let running = await queue.suspendJobs(touching: mountPoint)
                if !running.isEmpty, let report = self?.onRunningJobsOnReleasedVolume { await report(id, running) }
            }
        })
    }

    /// Jobs running now that touch `volume` (no state change). Eject asks cancel/wait with these before unmounting.
    public func runningJobs(on volume: VolumeID) async -> [JobID] {
        guard let mountPoint = volumes.list.first(where: { $0.id == volume })?.mountPoint else { return [] }
        return await fileOps.runningJobs(touching: mountPoint)
    }

    public func folderContext() -> FolderContext {
        let settings = self.settings, volumes = self.volumes
        return FolderContext(
            readers: readers, lanes: lanes, volumes: volumes, changeBus: changeBus, types: types,
            pacer: TimerFramePacer(),
            makeWatcher: { directory, since, handler in Watcher(directory: directory, since: since, handler: handler) },
            permissionPending: { url in
                guard let location = Self.protectedLocation(url, settings: settings, volumes: volumes) else { return false }
                return settings.tccOutcome(for: location) == nil
            },
            recordPermissionOutcome: { url, granted in
                guard let location = Self.protectedLocation(url, settings: settings, volumes: volumes) else { return }
                settings.recordTCCOutcome(granted ? .granted : .denied, for: location)
            },
            home: settings.home, ownerNames: ownerNames)
    }

    static func protectedLocation(_ url: URL, settings: Settings, volumes: Volumes) -> ProtectedLocation? {
        ProtectedLocations.classify(url, home: settings.home, volume: volumes.volume(for: url))
    }

    public func makeFolderModel(_ directory: URL, query: ViewQuery? = nil) -> FolderModel {
        FolderModel(directory: directory, context: folderContext(), query: query ?? settings.viewQuery())
    }

    /// Idempotent. Launch recovery first (§6.3: partials removed, trashed destinations restored, incomplete jobs
    /// reported), then jobs may run, then the operations consumer and the volume list start.
    public func start() async -> RecoveryReport {
        if let startTask { return await startTask.value }
        let journal = self.journal, lanes = self.lanes, queue = fileOps, operations = self.operations, volumes = self.volumes
        let task = Task { () -> RecoveryReport in
            let report = await LaunchRecovery.run(journal: journal, lanes: lanes)
            operations.start()
            await queue.releaseHold()
            await volumes.start()
            return report
        }
        startTask = task
        return await task.value
    }

    // MARK: sandbox

    nonisolated static let sandboxPrefixes = ["macx-tests-", "macx-bench-", "macx-scenario-", "macx-fixtures-"]

    /// "/private/var/…" and "/var/…" (and /tmp) name the same place; compare one spelling. Pure string work.
    nonisolated static func canonicalTempPath(_ path: String) -> String {
        for p in ["/private/var/", "/private/tmp/"] where path.hasPrefix(p) { return String(path.dropFirst("/private".count)) }
        return path
    }

    /// Pure: a `macx-*-<something>` directory somewhere inside the temporary directory (no file-system call).
    nonisolated static func isSandboxRoot(_ url: URL) -> Bool {
        let path = canonicalTempPath(url.standardizedFileURL.path)
        var tmp = canonicalTempPath(FileManager.default.temporaryDirectory.standardizedFileURL.path)
        if !tmp.hasSuffix("/") { tmp += "/" }
        guard path.hasPrefix(tmp), path.count > tmp.count else { return false }
        let name = (path as NSString).lastPathComponent
        return sandboxPrefixes.contains { name.hasPrefix($0) && name.count > $0.count }
    }

    /// Test/scenario factory (§3.12). Everything lives inside `root`; nothing is written until used.
    public static func sandboxed(root: URL) -> CoreEnvironment {
        precondition(isSandboxRoot(root), "CoreEnvironment.sandboxed requires a macx-* sandbox root in the temporary directory, got \(root.path)")
        // Keep the caller's spelling (standardizedFileURL turns an existing /private/var root into /var), so
        // service paths compare equal to the URLs the caller builds from the same root.
        let base = root.absoluteURL
        let lanes = LanePool()
        return CoreEnvironment(
            statePaths: StatePaths(root: base.appending(path: "state", directoryHint: .isDirectory)),
            lanes: lanes, settingsStorage: InMemorySettingsStorage(), volumeScanner: SystemVolumeScanner(),
            volumeEvents: nil, pasteboard: InMemoryPasteboard(), launchServices: FakeLaunchServices(),
            ejector: SandboxEjector(root: base, lanes: lanes),
            trash: SandboxTrash(directory: base.appending(path: ".trash", directoryHint: .isDirectory)),
            fileOpTuning: FileOpTuning(), home: base, interactionTarget: ScriptedInteraction())
    }
}
