import Foundation
import Observation

/// Main-actor volume registry (§4.2 Volumes): list, mount table, capacity cache, release handlers.
@MainActor @Observable
public final class Volumes {
    public private(set) var list: [VolumeInfo] = []          // all mounted
    public var browsable: [VolumeInfo] { list.filter(\.isBrowsable) }
    public private(set) var mountTable: MountTable = .empty
    @ObservationIgnored public let mountTableStore = MountTableStore()

    @ObservationIgnored private let lanes: LanePool
    @ObservationIgnored private let scanner: any VolumeScanning
    @ObservationIgnored private let events: (any VolumeEventSource)?
    @ObservationIgnored private var capacity: [VolumeID: Int64] = [:]
    @ObservationIgnored private var handlers: [UInt64: @MainActor (VolumeID) async -> Void] = [:]
    @ObservationIgnored private var nextHandler: UInt64 = 0
    @ObservationIgnored private let listObservers = Observers<[VolumeInfo]>()
    @ObservationIgnored private var started = false

    public init(lanes: LanePool, scanner: any VolumeScanning = SystemVolumeScanner(), events: (any VolumeEventSource)?) {
        self.lanes = lanes
        self.scanner = scanner
        self.events = events
    }

    /// Initial scan on a lane + subscribe to events.
    public func start() async {
        await refresh()
        guard !started else { return }
        started = true
        events?.start { [weak self] event in
            Task { @MainActor in await self?.handle(event) }
        }
    }

    public func refresh() async {
        let scanner = self.scanner
        guard let scanned = try? await lanes.perform(on: .unknown, .read, { _ in try scanner.scan() }) else { return }
        let sorted = scanned.sorted { a, b in
            if a.isBoot != b.isBoot { return a.isBoot }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        let old = Set(list.map(\.id))
        for v in sorted where !old.contains(v.id) { await lanes.resetVolume(v.id) }   // remounted / reappeared
        let gone = old.subtracting(sorted.map(\.id))
        for id in gone { capacity[id] = nil }
        guard sorted != list else { return }
        list = sorted
        mountTable = MountTable(sorted)
        mountTableStore.update(mountTable)
        listObservers.send(sorted)
    }

    /// Rescan; willUnmount → release first (the volume is still mounted then).
    public func handle(_ event: VolumeEvent) async {
        if case .willUnmount(let url) = event, let v = volume(for: url) {
            await release(v.id)
        }
        await refresh()
    }

    public func volume(for url: URL) -> VolumeInfo? { mountTable.volume(containing: url.path(percentEncoded: false)) }

    public func cachedAvailableCapacity(_ volume: VolumeID) -> Int64? { capacity[volume] }

    public func refreshAvailableCapacity(_ volume: VolumeID) async -> Int64? {
        guard let info = list.first(where: { $0.id == volume }) else { return nil }
        let scanner = self.scanner, mount = info.mountPoint
        guard let value = try? await lanes.perform(on: volume, .read, { _ in scanner.availableCapacity(of: mount) }) else {
            return capacity[volume]
        }
        capacity[volume] = value
        return value
    }

    /// Runs every release handler in registration order (cancel reads ≤1 s, stop watchers, pause jobs, move windows home).
    public func release(_ volume: VolumeID) async {
        for key in handlers.keys.sorted() {
            if let handler = handlers[key] { await handler(volume) }
        }
    }

    public func addReleaseHandler(_ handler: @escaping @MainActor (VolumeID) async -> Void) -> ObserverToken {
        nextHandler += 1
        let key = nextHandler
        handlers[key] = handler
        return ObserverToken { [weak self] in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.handlers[key] = nil }
            } else {
                Task { @MainActor in self?.handlers[key] = nil }
            }
        }
    }

    public func observe(_ handler: @escaping @MainActor ([VolumeInfo]) -> Void) -> ObserverToken {
        listObservers.add(handler)
    }
}
