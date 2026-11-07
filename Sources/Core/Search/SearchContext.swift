import Foundation
import MacxFS

/// Spotlight, index status and iCloud download services, real or fake (sandboxed runs never touch the index or iCloud).
public struct SearchServices: Sendable {
    public var metadataQuery: any MetadataQuerying
    public var indexStatus: any IndexStatusProviding
    public var downloader: any UbiquitousDownloading
    public init(metadataQuery: any MetadataQuerying, indexStatus: any IndexStatusProviding, downloader: any UbiquitousDownloading) {
        self.metadataQuery = metadataQuery; self.indexStatus = indexStatus; self.downloader = downloader
    }
    public static func system(lanes: LanePool) -> SearchServices {
        SearchServices(metadataQuery: SystemMetadataQuery(), indexStatus: MdutilIndexStatus(lanes: lanes),
                       downloader: SystemUbiquitousDownloader(lanes: lanes))
    }
    /// Sandboxed runs and tests: no Spotlight index access, no real downloads.
    public static func fake(items: [MetadataItem] = [], indexing: IndexingStatus = .disabled) -> SearchServices {
        SearchServices(metadataQuery: FakeMetadataQuery(items: items), indexStatus: FixedIndexStatus(indexing),
                       downloader: FakeUbiquitousDownloader())
    }
}

/// What a search needs from the environment (CoreEnvironment.searchContext()).
@MainActor
public struct SearchContext {
    public var lanes: LanePool
    public var volumes: Volumes
    public var types: TypeRegistry
    public var changeBus: ChangeBus
    public var settings: Settings
    public var pacer: any FramePacer
    public var services: SearchServices
    public var now: @Sendable () -> Date
    public var calendar: Calendar

    public init(lanes: LanePool, volumes: Volumes, types: TypeRegistry, changeBus: ChangeBus, settings: Settings,
                pacer: any FramePacer, services: SearchServices,
                now: @escaping @Sendable () -> Date = { Date() }, calendar: Calendar = .current) {
        self.lanes = lanes; self.volumes = volumes; self.types = types; self.changeBus = changeBus
        self.settings = settings; self.pacer = pacer; self.services = services; self.now = now; self.calendar = calendar
    }

    /// Resolves the spec and routes it. Asks the index-status provider only when the route depends on it: about the
    /// boot volume for This Mac, otherwise about the root's volume.
    public func plan(_ spec: SearchSpec) async -> SearchPlan {
        let resolved = SearchResolver.resolve(spec, now: now(), calendar: calendar)
        let volume = volumes.volume(for: spec.root)
        let slash = URL(filePath: "/", directoryHint: .isDirectory)
        var rootStatus = IndexingStatus.unknown, bootStatus = IndexingStatus.unknown
        if SearchPlanner.needsIndexStatus(spec) {
            if spec.scope == .thisMac {
                let boot = volumes.list.first(where: \.isBoot)?.mountPoint ?? slash
                bootStatus = await services.indexStatus.status(ofVolumeAt: boot)
            } else {
                rootStatus = await services.indexStatus.status(ofVolumeAt: volume?.mountPoint ?? slash)
            }
        }
        let inputs = PlanInputs(rootIndexing: rootStatus, bootIndexing: bootStatus, rootIsLocal: volume?.isLocal ?? true,
                                rootVolumeName: volume?.name ?? spec.root.lastPathComponent)
        return SearchPlanner.plan(spec, resolved: resolved, inputs: inputs)
    }

    /// TCC-protected folders the crawler must not open (from the outcomes Phase 1 recorded while browsing).
    public func crawlPermissions() -> CrawlPermissions {
        var known: [ProtectedLocation: TCCOutcome] = [:]
        for location in [ProtectedLocation.desktop, .documents, .downloads, .iCloudDrive] {
            if let o = settings.tccOutcome(for: location) { known[location] = o }
        }
        return CrawlPermissions.make(home: settings.home) { known[$0] }
    }
}

extension CrawlPermissions {
    /// Folders whose opening could raise a TCC prompt. Desktop/Documents/Downloads/iCloud Drive are blocked
    /// unless a grant was recorded (Phase 1 records outcomes when the user browses them); app-data locations always.
    static let alwaysBlocked = [
        "Library/Containers", "Library/Group Containers", "Library/Mail", "Library/Messages", "Library/Safari",
        "Library/Cookies", "Library/HomeKit", "Library/Calendars", "Library/Reminders", "Library/Biome",
        "Library/Application Support/AddressBook", "Library/Application Support/CallHistoryDB",
        "Library/Application Support/com.apple.TCC", "Library/Suggestions", "Library/Metadata/CoreSpotlight", ".Trash",
    ]

    public static func make(home: URL, outcome: (ProtectedLocation) -> TCCOutcome?) -> CrawlPermissions {
        let h = trim(SearchResultStore.standardizedParent(home))
        let base = h == "/" ? "" : h
        var blocked: [String] = []
        let protected: [(ProtectedLocation, String)] = [(.desktop, "Desktop"), (.documents, "Documents"),
                                                        (.downloads, "Downloads"), (.iCloudDrive, "Library/Mobile Documents")]
        for (location, relative) in protected where outcome(location) != .granted { blocked.append(base + "/" + relative) }
        blocked += alwaysBlocked.map { base + "/" + $0 }
        return CrawlPermissions(blockedPrefixes: blocked)
    }
}
