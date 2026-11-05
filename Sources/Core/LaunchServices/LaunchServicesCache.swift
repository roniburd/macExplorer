import Foundation
import MacxFS
import UniformTypeIdentifiers

/// Main-actor LaunchServices caches (§4.3, §5.6 Open With): candidate apps per UTType (served stale and refreshed
/// in the background) and the default app per file (honours per-file overrides; cached briefly). Lookups never
/// happen while a caller waits: a miss returns nil, schedules one background fetch per key, and observers receive
/// the file URL when its data lands.
@MainActor
public final class LaunchServicesCache {
    public let provider: any LaunchServicesProviding
    private let types: TypeRegistry
    /// Time source for entry ages (injectable so expiry can be tested without wall-clock sleeps).
    private let now: @MainActor () -> ContinuousClock.Instant

    /// How long a per-file default stays valid (spec: "cached briefly per file URL").
    public var defaultLifetime: Duration = .seconds(30)
    /// After this, a hit on a type's app list is still served but triggers a background refresh.
    public var applicationsLifetime: Duration = .seconds(300)
    /// Per-file default entries kept before expired ones are pruned (and, if still over, all are dropped).
    public var maxDefaultEntries = 1_024

    private struct AppsEntry { var apps: [AppInfo]; var fetched: ContinuousClock.Instant; var stale: Bool }
    private struct DefaultEntry { var app: AppInfo?; var fetched: ContinuousClock.Instant }

    private var apps: [String: AppsEntry] = [:]               // UTType identifier → apps
    private var appsInFlight: Set<String> = []
    private var appsWaiters: [String: [URL]] = [:]            // files to notify when a type's apps land
    private var defaults: [String: DefaultEntry] = [:]        // standardized path → default
    private var defaultsInFlight: [String: UInt64] = [:]      // path → generation the fetch started at
    private var defaultsWaiters: [String: [URL]] = [:]
    private var generations: [String: UInt64] = [:]           // bumped by invalidate(file:)
    private var fileTypes: [String: String] = [:]             // path → UTType identifier last seen
    private let observers = Observers<URL>()

    public init(provider: any LaunchServicesProviding, types: TypeRegistry = .shared,
                now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.provider = provider
        self.types = types
        self.now = now
    }

    /// Cache hit or nil (a miss schedules a background fetch; observers fire when it lands). Never blocks.
    public func cachedApplications(for file: URL, typeIndex: UInt16) -> [AppInfo]? {
        let type = typeKey(typeIndex)
        fileTypes[fileKey(file)] = type
        guard let entry = apps[type] else {
            fetchApplications(type: type, sample: file)
            return nil
        }
        if entry.stale || now() - entry.fetched > applicationsLifetime {
            fetchApplications(type: type, sample: file)
        }
        return entry.apps
    }

    /// `.some(nil)` = known "no default"; nil = not known yet (a fetch is scheduled).
    public func cachedDefault(for file: URL) -> AppInfo?? {
        let key = fileKey(file)
        if let entry = defaults[key], now() - entry.fetched <= defaultLifetime {
            return .some(entry.app)
        }
        defaults[key] = nil
        fetchDefault(key: key, file: file)
        return nil
    }

    public func prefetch(file: URL, typeIndex: UInt16) {
        _ = cachedApplications(for: file, typeIndex: typeIndex)
        _ = cachedDefault(for: file)
    }

    /// Watcher change or default changed: drops the file's default (and those of other files of its type, whose
    /// type default may have changed too) and marks the type's app list for a background refresh.
    public func invalidate(file: URL) {
        let key = fileKey(file)
        generations[key, default: 0] += 1
        defaults[key] = nil
        guard let type = fileTypes[key] else { return }
        apps[type]?.stale = true
        for (other, otherType) in fileTypes where otherType == type && other != key {
            generations[other, default: 0] += 1
            defaults[other] = nil
        }
    }

    public func observe(_ handler: @escaping @MainActor (URL) -> Void) -> ObserverToken {
        observers.add(handler)
    }

    // MARK: fetching

    private func fetchApplications(type: String, sample file: URL) {
        if !appsWaiters[type, default: []].contains(file) { appsWaiters[type, default: []].append(file) }
        guard appsInFlight.insert(type).inserted else { return }
        let provider = self.provider
        Task { [weak self] in
            let found = await provider.applications(toOpen: file)
            self?.landApplications(found, type: type)
        }
    }

    private func landApplications(_ found: [AppInfo], type: String) {
        appsInFlight.remove(type)
        apps[type] = AppsEntry(apps: found, fetched: now(), stale: false)
        let waiters = appsWaiters.removeValue(forKey: type) ?? []
        for file in waiters { observers.send(file) }
    }

    private func fetchDefault(key: String, file: URL) {
        if !defaultsWaiters[key, default: []].contains(file) { defaultsWaiters[key, default: []].append(file) }
        guard defaultsInFlight[key] == nil else { return }
        let generation = generations[key, default: 0]
        defaultsInFlight[key] = generation
        let provider = self.provider
        Task { [weak self] in
            let found = await provider.defaultApplication(toOpen: file)
            self?.landDefault(found, key: key, file: file, generation: generation)
        }
    }

    private func landDefault(_ found: AppInfo?, key: String, file: URL, generation: UInt64) {
        defaultsInFlight[key] = nil
        guard generations[key, default: 0] == generation else {
            fetchDefault(key: key, file: file)   // invalidated meanwhile: the answer may be outdated
            return
        }
        if defaults.count >= maxDefaultEntries { prune() }
        defaults[key] = DefaultEntry(app: found, fetched: now())
        let waiters = defaultsWaiters.removeValue(forKey: key) ?? []
        for file in waiters { observers.send(file) }
    }

    private func prune() {
        let time = now()
        defaults = defaults.filter { time - $0.value.fetched <= defaultLifetime }
        if defaults.count >= maxDefaultEntries { defaults.removeAll() }
        if fileTypes.count >= maxDefaultEntries * 4 { fileTypes.removeAll() }
    }

    private func typeKey(_ index: UInt16) -> String { types.type(at: index).identifier }

    private func fileKey(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
