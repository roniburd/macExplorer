import Darwin
import Foundation
import MacxFixtures
@testable import MacxFS
import Synchronization
import XCTest

private func volume(_ id: String, _ path: String, boot: Bool = false, browsable: Bool = true,
                    caps: VolumeCapabilities = VolumeCapabilities(idStable: true, renameExcl: true, clone: true, caseSensitive: false)) -> VolumeInfo {
    VolumeInfo(id: VolumeID(raw: id), mountPoint: URL(filePath: path, directoryHint: .isDirectory), name: id, format: "APFS",
               isBoot: boot, isInternal: boot, isRemovable: !boot, isEjectable: !boot, isLocal: true, isReadOnly: false,
               isBrowsable: browsable, totalCapacity: 1_000, capabilities: caps)
}

final class FakeScanner: VolumeScanning {
    let volumes: Mutex<[VolumeInfo]>
    let capacity = Mutex<Int64?>(4_242)
    init(_ v: [VolumeInfo]) { volumes = Mutex(v) }
    func scan() throws -> [VolumeInfo] { volumes.withLock { $0 } }
    func availableCapacity(of mountPoint: URL) -> Int64? { capacity.withLock { $0 } }
    func set(_ v: [VolumeInfo]) { volumes.withLock { $0 = v } }
}

/// Snapshots its volumes when a scan starts; the first `blocked` scans then wait on `gate` before returning.
final class GatedScanner: VolumeScanning {
    let volumes: Mutex<[VolumeInfo]>
    let blocked: Mutex<Int>
    let started = Mutex(0)
    let gate = Gate()
    init(_ v: [VolumeInfo], blocked: Int) { volumes = Mutex(v); self.blocked = Mutex(blocked) }
    func scan() throws -> [VolumeInfo] {
        let snapshot = volumes.withLock { $0 }
        started.withLock { $0 += 1 }
        let block = blocked.withLock { b -> Bool in defer { b = max(0, b - 1) }; return b > 0 }
        if block { gate.wait() }
        return snapshot
    }
    func availableCapacity(of mountPoint: URL) -> Int64? { nil }
    func set(_ v: [VolumeInfo]) { volumes.withLock { $0 = v } }
}

@MainActor
final class FakeEvents: VolumeEventSource {
    var handler: (@MainActor (VolumeEvent) -> Void)?
    func start(_ handler: @escaping @MainActor (VolumeEvent) -> Void) { self.handler = handler }
}

final class MountTableTests: XCTestCase {
    private let table = MountTable([volume("boot", "/", boot: true), volume("usb", "/Volumes/USB"),
                                    volume("usb2", "/Volumes/USB 2"), volume("data", "/System/Volumes/Data", browsable: false)])

    func testLongestPrefixMatch() {
        XCTAssertEqual(table.volume(containing: "/Users/me/file")?.id.raw, "boot")
        XCTAssertEqual(table.volume(containing: "/Volumes/USB")?.id.raw, "usb")
        XCTAssertEqual(table.volume(containing: "/Volumes/USB/a/b")?.id.raw, "usb")
        XCTAssertEqual(table.volume(containing: "/Volumes/USB 2/x")?.id.raw, "usb2")
        XCTAssertEqual(table.volume(containing: "/Volumes/USBX/x")?.id.raw, "boot", "prefix must end at a path component")
        XCTAssertEqual(table.volume(containing: "/Volumes/USB/../USB 2/x")?.id.raw, "usb2", "standardized first")
        XCTAssertEqual(table.volume(containing: "/System/Volumes/Data/Users")?.id.raw, "data")
        XCTAssertNil(MountTable.empty.volume(containing: "/x"))
    }

    func testPrivateFirmlinkSpellingsMatchEitherWay() {
        let images = MountTable([volume("boot", "/", boot: true), volume("img", "/private/var/folders/T/mnt-x"),
                                 volume("tmpimg", "/tmp/mnt-y")])
        XCTAssertEqual(images.volume(containing: "/var/folders/T/mnt-x/f")?.id.raw, "img", "standardizedFileURL spelling")
        XCTAssertEqual(images.volume(containing: "/private/var/folders/T/mnt-x/f")?.id.raw, "img")
        XCTAssertEqual(images.volume(containing: "/private/tmp/mnt-y")?.id.raw, "tmpimg")
        XCTAssertEqual(images.volume(containing: "/var/folders/T/other")?.id.raw, "boot")
        XCTAssertEqual(images.volume(containing: "/private/varx/mnt-x")?.id.raw, "boot", "only whole components are mapped")
        XCTAssertTrue(images.isSameVolume("/var/folders/T/mnt-x/a", "/private/var/folders/T/mnt-x/b"))
    }

    func testIsSameVolume() {
        XCTAssertTrue(table.isSameVolume("/Users/a", "/Applications/b"))
        XCTAssertFalse(table.isSameVolume("/Users/a", "/Volumes/USB/b"))
        XCTAssertFalse(MountTable.empty.isSameVolume("/a", "/a"))
    }

    func testStoreMirrorsUpdates() {
        let store = MountTableStore()
        XCTAssertEqual(store.current(), .empty)
        store.update(table)
        XCTAssertEqual(store.current().volume(containing: "/Volumes/USB/x")?.id.raw, "usb")
    }

    func testIdentityModeFollowsCapabilities() {
        XCTAssertEqual(VolumeCapabilities(idStable: true, renameExcl: true, clone: true, caseSensitive: false).identityMode, .objectID)
        XCTAssertEqual(VolumeCapabilities(idStable: false, renameExcl: false, clone: false, caseSensitive: false).identityMode,
                       .name(caseSensitive: false))
    }

    func testDirectoryReadersPickReaderByVolume() {
        let store = MountTableStore(table)
        let readers = DirectoryReaders(lanes: LanePool(), mountTable: store)
        XCTAssertEqual(readers.reader(for: URL(filePath: "/Volumes/USB/x")).volume.raw, "usb")
        XCTAssertTrue(readers.reader(for: URL(filePath: "/Volumes/USB/y")) === readers.reader(for: VolumeID(raw: "usb")))
        XCTAssertEqual(DirectoryReaders(lanes: LanePool(), mountTable: MountTableStore()).reader(for: URL(filePath: "/x")).volume, .unknown)
    }
}

@MainActor
final class VolumesTests: XCTestCase {
    func testStartScansSortsAndPublishesMirror() async {
        let scanner = FakeScanner([volume("usb", "/Volumes/USB"), volume("data", "/System/Volumes/Data", browsable: false),
                                   volume("boot", "/", boot: true)])
        let volumes = Volumes(lanes: LanePool(), scanner: scanner, events: nil)
        await volumes.start()
        XCTAssertEqual(volumes.list.map(\.id.raw), ["boot", "data", "usb"], "boot first, then by name")
        XCTAssertEqual(volumes.browsable.map(\.id.raw), ["boot", "usb"])
        XCTAssertEqual(volumes.volume(for: URL(filePath: "/Volumes/USB/f"))?.id.raw, "usb")
        XCTAssertEqual(volumes.mountTableStore.current(), volumes.mountTable)
    }

    func testEventsRescanAndWillUnmountReleasesFirst() async {
        let scanner = FakeScanner([volume("boot", "/", boot: true), volume("usb", "/Volumes/USB")])
        let events = FakeEvents()
        let volumes = Volumes(lanes: LanePool(), scanner: scanner, events: events)
        await volumes.start()
        var log: [String] = []
        var changes: [[String]] = []
        let a = volumes.addReleaseHandler { id in log.append("cancel reads \(id.raw)") }
        let b = volumes.addReleaseHandler { id in log.append("move windows \(id.raw)") }
        let c = volumes.observe { list in changes.append(list.map(\.id.raw)) }
        await volumes.handle(.willUnmount(URL(filePath: "/Volumes/USB")))
        XCTAssertEqual(log, ["cancel reads usb", "move windows usb"], "handlers run in registration order")
        scanner.set([volume("boot", "/", boot: true)])
        await volumes.handle(.didUnmount(URL(filePath: "/Volumes/USB")))
        XCTAssertEqual(volumes.list.map(\.id.raw), ["boot"])
        scanner.set([volume("boot", "/", boot: true), volume("cam", "/Volumes/CAM")])
        events.handler?(.didMount(URL(filePath: "/Volumes/CAM")))
        let mounted = await eventuallyMain { volumes.list.count == 2 }
        XCTAssertTrue(mounted)
        XCTAssertEqual(changes, [["boot"], ["boot", "cam"]])
        a.cancel()
        await volumes.release(VolumeID(raw: "cam"))
        XCTAssertEqual(log.last, "move windows cam", "cancelled handler no longer runs")
        _ = (b, c)
    }

    func testReappearingVolumeResetsUnresponsiveMark() async throws {
        let lanes = LanePool(config: WatchdogConfig(stallTimeout: .milliseconds(100), tick: .milliseconds(20), lanesPerClass: 1, poisonCap: 1))
        let scanner = FakeScanner([volume("boot", "/", boot: true)])
        let volumes = Volumes(lanes: lanes, scanner: scanner, events: nil)
        await volumes.start()
        let nas = VolumeID(raw: "nas")
        let gate = Gate()
        let hung = Task { try await lanes.perform(on: nas) { _ in gate.wait() } }
        let unresponsive = await eventually { await lanes.health(of: nas) == .unresponsive }
        XCTAssertTrue(unresponsive)
        scanner.set([volume("boot", "/", boot: true), volume("nas", "/Volumes/NAS")])
        await volumes.handle(.didMount(URL(filePath: "/Volumes/NAS")))
        let health = await lanes.health(of: nas)
        XCTAssertEqual(health, .healthy)
        gate.open()
        _ = try await hung.value
    }

    func testOlderScanFinishingLastDoesNotOverwriteNewerResult() async {
        let scanner = GatedScanner([volume("boot", "/", boot: true), volume("usb", "/Volumes/USB")], blocked: 1)
        let volumes = Volumes(lanes: LanePool(), scanner: scanner, events: nil)
        let first = Task { await volumes.refresh() }                  // sees usb mounted, then hangs
        let firstStarted = await eventually { scanner.started.withLock { $0 } == 1 }
        XCTAssertTrue(firstStarted)
        scanner.set([volume("boot", "/", boot: true)])                // usb unmounted
        await volumes.refresh()
        XCTAssertEqual(volumes.list.map(\.id.raw), ["boot"])
        scanner.gate.open()
        await first.value
        XCTAssertEqual(volumes.list.map(\.id.raw), ["boot"], "stale scan dropped: no ghost volume")
        XCTAssertEqual(volumes.mountTableStore.current().volume(containing: "/Volumes/USB/f")?.id.raw, "boot")
    }

    func testHungUnmappedReadsDoNotStopRefresh() async throws {
        let lanes = LanePool(config: WatchdogConfig(stallTimeout: .milliseconds(100), tick: .milliseconds(20), lanesPerClass: 4, poisonCap: 4))
        let scanner = FakeScanner([volume("boot", "/Volumes/BootLike", boot: true)])
        let volumes = Volumes(lanes: lanes, scanner: scanner, events: nil)
        let gate = Gate()
        let hung = (0..<4).map { _ in Task { try await lanes.perform(on: .unknown) { ctx in ctx.heartbeat(); gate.wait() } } }
        let unresponsive = await eventually { await lanes.health(of: .unknown) == .unresponsive }
        XCTAssertTrue(unresponsive)
        await volumes.start()
        XCTAssertEqual(volumes.list.map(\.id.raw), ["boot"], "the scan has its own lane")
        scanner.set([volume("boot", "/Volumes/BootLike", boot: true), volume("cam", "/Volumes/CAM")])
        await volumes.handle(.didMount(URL(filePath: "/Volumes/CAM")))
        XCTAssertEqual(volumes.list.map(\.id.raw), ["boot", "cam"])
        gate.open(count: 4)
        for t in hung { _ = try? await t.value }
    }

    func testUnresponsiveScanLaneIsResetSoLaterRefreshesWork() async throws {
        let lanes = LanePool(config: WatchdogConfig(stallTimeout: .milliseconds(100), tick: .milliseconds(20), lanesPerClass: 1, poisonCap: 1))
        let scanner = GatedScanner([volume("boot", "/", boot: true), volume("nas", "/Volumes/NAS")], blocked: 1)
        let volumes = Volumes(lanes: lanes, scanner: scanner, events: nil)
        let hung = Task { await volumes.refresh() }                   // scan blocks on a dead mount
        let poisoned = await eventually { await lanes.health(of: Volumes.scanVolume) == .unresponsive }
        XCTAssertTrue(poisoned)
        await volumes.refresh()                                       // fails fast, resets the scan lane
        let health = await lanes.health(of: Volumes.scanVolume)
        XCTAssertEqual(health, .healthy)
        scanner.set([volume("boot", "/", boot: true)])
        await volumes.refresh()
        XCTAssertEqual(volumes.list.map(\.id.raw), ["boot"])
        scanner.gate.open()
        await hung.value
        XCTAssertEqual(volumes.list.map(\.id.raw), ["boot"], "the late hung scan is stale")
    }

    func testStartReturnsAndSubscribesWhileTheInitialScanHangs() async {
        let scanner = GatedScanner([volume("boot", "/", boot: true)], blocked: 1)   // dead SMB mount at launch
        let events = FakeEvents()
        let volumes = Volumes(lanes: LanePool(), scanner: scanner, events: events)
        let start = ContinuousClock.now
        await volumes.start(initialScanTimeout: .milliseconds(100))
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
        XCTAssertNotNil(events.handler, "events are subscribed even though the scan has not finished")
        XCTAssertEqual(volumes.list, [])
        scanner.gate.open()
        let applied = await eventuallyMain { volumes.list.map(\.id.raw) == ["boot"] }
        XCTAssertTrue(applied, "the late initial scan is applied when it finishes")
    }

    func testCapacityIsFetchedOnALaneAndCached() async {
        let scanner = FakeScanner([volume("boot", "/", boot: true)])
        let volumes = Volumes(lanes: LanePool(), scanner: scanner, events: nil)
        await volumes.start()
        let boot = VolumeID(raw: "boot")
        XCTAssertNil(volumes.cachedAvailableCapacity(boot))
        let fetched = await volumes.refreshAvailableCapacity(boot)
        XCTAssertEqual(fetched, 4_242)
        XCTAssertEqual(volumes.cachedAvailableCapacity(boot), 4_242)
        let unknown = await volumes.refreshAvailableCapacity(VolumeID(raw: "nope"))
        XCTAssertNil(unknown)
    }

    private func eventuallyMain(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

final class SystemVolumeScannerTests: XCTestCase {
    private var sandbox: Sandbox!

    override func setUpWithError() throws {
        sandbox = try Sandbox()
        let s = sandbox!
        addTeardownBlock { s.destroy() }
    }

    private func scan() async throws -> [VolumeInfo] {
        try await LanePool().perform(on: .unknown) { _ in try SystemVolumeScanner().scan() }
    }

    func testBootVolumeIsPresentAndWritableThroughData() async throws {
        let volumes = try await scan()
        let boot = try XCTUnwrap(volumes.first { $0.isBoot })
        XCTAssertEqual(boot.mountPoint.path(percentEncoded: false), "/")
        XCTAssertTrue(boot.isBrowsable)
        XCTAssertTrue(boot.capabilities.idStable)
        XCTAssertFalse(boot.isReadOnly, "takes the Data volume's writability")
        XCTAssertTrue(boot.id.raw.hasPrefix("uuid:"))
        let table = MountTable(volumes)
        XCTAssertEqual(table.volume(containing: NSHomeDirectory())?.id, boot.id)
        let capacity = try await LanePool().perform(on: boot.id) { _ in SystemVolumeScanner().availableCapacity(of: boot.mountPoint) }
        XCTAssertGreaterThan(capacity ?? 0, 0)
    }

    func testDiskImagesAppearWithCapabilitiesAndDisappearAfterDetach() async throws {
        try XCTSkipUnless(DiskImage.isAvailable, "hdiutil not available")
        let expectations: [(DiskImageFormat, IdentityMode, Bool)] = [
            (.apfs, .objectID, true), (.exfat, .name(caseSensitive: false), false), (.msdos, .name(caseSensitive: false), false),
        ]
        for (format, mode, clone) in expectations {
            let image = try DiskImage.create(in: sandbox, format: format, sizeMB: 16, volumeName: "MACXVOL")
            let mounted = try await scan().first { $0.mountPoint.path(percentEncoded: false).trimmingCharacters(in: ["/"]) ==
                                                       image.mountPoint.path(percentEncoded: false).trimmingCharacters(in: ["/"]) }
            let info = try XCTUnwrap(mounted, "\(format) image not in scan")
            XCTAssertFalse(info.isBrowsable, "\(format): -nobrowse images stay out of the sidebar")
            XCTAssertEqual(info.capabilities.identityMode, mode, "\(format)")
            XCTAssertEqual(info.capabilities.clone, clone, "\(format)")
            XCTAssertFalse(info.isBoot)
            let table = MountTable(try await scan())
            XCTAssertEqual(table.volume(containing: image.mountPoint.path(percentEncoded: false) + "/x")?.id, info.id)
            let standardized = image.mountPoint.standardizedFileURL.path(percentEncoded: false) + "/x"   // existing paths lose /private
            XCTAssertTrue(standardized.hasPrefix("/var/"), "sandbox lives under /private/var: \(standardized)")
            XCTAssertEqual(table.volume(containing: standardized)?.id, info.id, "\(format): /var spelling of the mount point")
            try image.detach()
            let after = try await scan().contains { $0.id == info.id }
            XCTAssertFalse(after, "\(format) still listed after detach")
        }
    }

    @MainActor
    func testVolumesHandleSeesRealImageMountAndUnmount() async throws {
        try XCTSkipUnless(DiskImage.isAvailable, "hdiutil not available")
        let volumes = Volumes(lanes: LanePool(), events: nil)
        await volumes.start()
        // Compare by this image's mount point, not list counts: parallel tests mount their own images.
        let image = try DiskImage.create(in: sandbox, format: .hfsPlus, sizeMB: 16)
        let mountPath = image.mountPoint.path(percentEncoded: false).trimmingCharacters(in: ["/"])
        let isThisImage: (VolumeInfo) -> Bool = { $0.mountPoint.path(percentEncoded: false).trimmingCharacters(in: ["/"]) == mountPath }
        await volumes.handle(.didMount(image.mountPoint))
        XCTAssertTrue(volumes.list.contains(where: isThisImage), "mounted image not in list")
        let info = try XCTUnwrap(volumes.volume(for: image.mountPoint.appending(path: "file")))
        XCTAssertTrue(isThisImage(info))
        XCTAssertFalse(info.isBoot)
        let free = await volumes.refreshAvailableCapacity(info.id)
        XCTAssertGreaterThan(free ?? 0, 0)
        try image.detach()
        await volumes.handle(.didUnmount(image.mountPoint))
        XCTAssertFalse(volumes.list.contains { $0.id == info.id }, "detached image still listed")
    }
}
