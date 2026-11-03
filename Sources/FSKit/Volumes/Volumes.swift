import Foundation
import Observation

/// Main-actor volume registry (§4.2 Volumes): list, mount table, capacity cache, release handlers.
@MainActor @Observable
public final class Volumes {
    /// Lane key for volume scans: separate from VolumeID.unknown, so hung reads of unmapped paths never
    /// block or poison the scan (and a hung scan never blocks those reads).
    public nonisolated static let scanVolume = VolumeID(raw: "system:volume-scan")

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
    @ObservationIgnored private var refreshesStarted: UInt64 = 0   // sequence number of the latest refresh() call
    @ObservationIgnored private var refreshApplied: UInt64 = 0     // sequence number of the newest scan applied

    public init(lanes: LanePool, scanner: any VolumeScanning = SystemVolumeScanner(), events: (any VolumeEventSource)?) {
        self.lanes = lanes
        self.scanner = scanner
        self.events = events
    }

    /// Subscribes to events first, then runs the initial scan on the scan lane and waits for it at most
    /// `initialScanTimeout`. A scan hung on a dead mount (SMB/NFS/automount at launch) never blocks app
    /// launch: start() returns with the list still empty and the scan is applied whenever it finishes.
    public func start(initialScanTimeout: Duration = .seconds(2)) async {
        if !started {
            started = true
            events?.start { [weak self] event in
                Task { @MainActor in await self?.handle(event) }
            }
        }
        let scan = Task { await self.refresh() }
        await Self.wait(for: scan, atMost: initialScanTimeout)
    }

    /// Returns when `task` finishes or `timeout` elapses, whichever comes first; `task` keeps running.
    private static func wait(for task: Task<Void, Never>, atMost timeout: Duration) async {
        final class Once { var continuation: CheckedContinuation<Void, Never>? }
        let once = Once()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            once.continuation = c
            let timer = Task { @MainActor in
                try? await Task.sleep(for: timeout)
                once.continuation?.resume()
                once.continuation = nil
            }
            Task { @MainActor in
                await task.value
                timer.cancel()
                once.continuation?.resume()
                once.continuation = nil
            }
        }
    }

    /// Scans on the dedicated scan lane. Refreshes may overlap (one Task per event); a scan that finishes
    /// after a newer one has been applied is dropped, so an old result never brings back a ghost volume.
    /// If the scan lane was marked unresponsive (a scan hung on a dead mount), it is reset so the next
    /// refresh tries again instead of failing for the rest of the session.
    public func refresh() async {
        refreshesStarted += 1
        let sequence = refreshesStarted
        let scanner = self.scanner
        let scanned: [VolumeInfo]
        do {
            scanned = try await lanes.perform(on: Volumes.scanVolume, .read) { _ in try scanner.scan() }
        } catch LaneError.volumeUnresponsive {
            await lanes.resetVolume(Volumes.scanVolume)
            return
        } catch {
            return
        }
        guard sequence > refreshApplied else { return }   // a newer scan already landed
        refreshApplied = sequence
        let sorted = scanned.sorted { a, b in
            if a.isBoot != b.isBoot { return a.isBoot }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        let old = Set(list.map(\.id))
        for v in sorted where !old.contains(v.id) { await lanes.resetVolume(v.id) }   // remounted / reappeared
        guard refreshApplied == sequence else { return }   // a newer scan landed during the resets
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
