import Darwin
import Foundation
import MacxFixtures
import MacxFS
import Synchronization
import XCTest
@testable import Core

private func volumeInfo(_ id: String, _ path: String) -> VolumeInfo {
    VolumeInfo(id: VolumeID(raw: id), mountPoint: URL(filePath: path, directoryHint: .isDirectory), name: id, format: "HFS+",
               isBoot: false, isInternal: false, isRemovable: true, isEjectable: true, isLocal: true, isReadOnly: false,
               isBrowsable: true, totalCapacity: 1_000,
               capabilities: VolumeCapabilities(idStable: true, renameExcl: true, clone: false, caseSensitive: false))
}

private final class ListScanner: VolumeScanning {
    let volumes: Mutex<[VolumeInfo]>
    let scans = Mutex(0)
    init(_ v: [VolumeInfo]) { volumes = Mutex(v) }
    func scan() throws -> [VolumeInfo] {
        scans.withLock { $0 += 1 }
        return volumes.withLock { $0 }
    }
    func availableCapacity(of mountPoint: URL) -> Int64? { nil }
    func set(_ v: [VolumeInfo]) { volumes.withLock { $0 = v } }
}

private final class EjectLog: Sendable {
    private let entries = Mutex<[String]>([])
    func add(_ s: String) { entries.withLock { $0.append(s) } }
    var all: [String] { entries.withLock { $0 } }
}

/// Answers eject attempts from a script (one result per attempt; the last repeats).
private final class ScriptedEjector: Ejecting {
    let log: EjectLog
    private let results: Mutex<[EjectError?]>
    private let onlyOwn: Bool
    private let holders: [String]
    let onEject: (@Sendable () -> Void)?

    init(log: EjectLog, results: [EjectError?], onlyOwn: Bool = false, holders: [String] = [],
         onEject: (@Sendable () -> Void)? = nil) {
        self.log = log
        self.results = Mutex(results)
        self.onlyOwn = onlyOwn
        self.holders = holders
        self.onEject = onEject
    }

    func eject(_ mountPoint: URL) async throws(EjectError) {
        log.add("eject \(mountPoint.lastPathComponent)")
        onEject?()
        let next = results.withLock { r -> EjectError? in r.count > 1 ? r.removeFirst() : r.first ?? nil }
        if let next { throw next }
    }
    func blockingProcesses(_ mountPoint: URL, timeout: Duration) async -> [String] {
        log.add("lsof")
        return holders
    }
    func onlyOwnProcessHolds(_ mountPoint: URL, timeout: Duration) async -> Bool {
        log.add("onlyOwn")
        return onlyOwn
    }
}

@MainActor
final class EjectCoordinatorTests: XCTestCase {
    private let usb = volumeInfo("uuid:usb", "/Volumes/USB")
    private var tokens: [ObserverToken] = []

    override func tearDown() async throws {
        tokens.forEach { $0.cancel() }
        tokens = []
    }

    private func make(_ ejector: ScriptedEjector, scanner: ListScanner? = nil) async -> (EjectCoordinator, Volumes) {
        let volumes = Volumes(lanes: LanePool(), scanner: scanner ?? ListScanner([usb]), events: nil)
        await volumes.refresh()
        let log = ejector.log
        tokens.append(volumes.addReleaseHandler { id in log.add("release \(id.raw)") })
        return (EjectCoordinator(volumes: volumes, ejector: ejector), volumes)
    }

    private func ejectError(_ coordinator: EjectCoordinator, _ volume: VolumeInfo) async -> EjectError? {
        do throws(EjectError) {
            try await coordinator.eject(volume)
            return nil
        } catch {
            return error
        }
    }

    func testReleasesBeforeEjecting() async {
        let log = EjectLog()
        let (coordinator, _) = await make(ScriptedEjector(log: log, results: [nil]))
        let error = await ejectError(coordinator, usb)
        XCTAssertNil(error)
        XCTAssertEqual(log.all, ["release uuid:usb", "eject USB"])
    }

    func testSuccessfulEjectRescansTheVolumeList() async {
        let log = EjectLog()
        let scanner = ListScanner([usb])
        let (coordinator, volumes) = await make(ScriptedEjector(log: log, results: [nil], onEject: { scanner.set([]) }),
                                                scanner: scanner)
        XCTAssertEqual(volumes.list.map(\.id), [usb.id])
        let error = await ejectError(coordinator, usb)
        XCTAssertNil(error)
        XCTAssertEqual(volumes.list, [], "the ejected volume is gone without waiting for a notification")
    }

    func testBusyHeldOnlyByUsReleasesAgainAndRetriesOnce() async {
        let log = EjectLog()
        let (coordinator, _) = await make(ScriptedEjector(log: log, results: [.busy(processes: []), nil], onlyOwn: true))
        let error = await ejectError(coordinator, usb)
        XCTAssertNil(error)
        XCTAssertEqual(log.all, ["release uuid:usb", "eject USB", "onlyOwn", "release uuid:usb", "eject USB"])
    }

    func testBusyHeldOnlyByUsTwiceReportsBusyAfterOneRetry() async {
        let log = EjectLog()
        let (coordinator, _) = await make(ScriptedEjector(log: log, results: [.busy(processes: [])], onlyOwn: true))
        let error = await ejectError(coordinator, usb)
        XCTAssertEqual(error, .busy(processes: []))
        XCTAssertEqual(log.all.filter { $0.hasPrefix("eject") }.count, 2, "retried exactly once")
        XCTAssertEqual(log.all.filter { $0.hasPrefix("release") }.count, 2)
    }

    func testBusyHeldByOthersReportsTheirNamesWithoutRetry() async {
        let log = EjectLog()
        let (coordinator, _) = await make(ScriptedEjector(log: log, results: [.busy(processes: ["Preview", "mds"])], onlyOwn: false))
        let error = await ejectError(coordinator, usb)
        XCTAssertEqual(error, .busy(processes: ["Preview", "mds"]))
        XCTAssertEqual(log.all, ["release uuid:usb", "eject USB", "onlyOwn"])
    }

    func testBusyWithoutNamesAsksForTheBlockingProcesses() async {
        let log = EjectLog()
        let (coordinator, _) = await make(ScriptedEjector(log: log, results: [.busy(processes: [])], onlyOwn: false,
                                                          holders: ["Terminal"]))
        let error = await ejectError(coordinator, usb)
        XCTAssertEqual(error, .busy(processes: ["Terminal"]))
    }

    func testOtherFailuresPassThroughWithoutRetry() async {
        let log = EjectLog()
        let failure = EjectError.failed(code: 5, message: "I/O error")
        let (coordinator, volumes) = await make(ScriptedEjector(log: log, results: [failure]))
        let error = await ejectError(coordinator, usb)
        XCTAssertEqual(error, failure)
        XCTAssertEqual(log.all, ["release uuid:usb", "eject USB"])
        XCTAssertEqual(volumes.list.map(\.id), [usb.id])
    }

    func testWorksWithAnyEjecting() async {
        let log = EjectLog()
        let ejector: any Ejecting = ScriptedEjector(log: log, results: [nil])
        let volumes = Volumes(lanes: LanePool(), scanner: ListScanner([usb]), events: nil)
        let coordinator = EjectCoordinator(volumes: volumes, ejector: ejector)
        let error = await ejectError(coordinator, usb)
        XCTAssertNil(error)
    }
}

final class LsofParsingTests: XCTestCase {
    func testParsesPidAndCommandFields() {
        let out = "p100\ncxctest\nf3\nf4\np1\nclaunchd\nftxt\np42\ncmds_stores\n"
        XCTAssertEqual(LsofHolders.parse(out), [.init(pid: 100, command: "xctest"), .init(pid: 1, command: "launchd"),
                                               .init(pid: 42, command: "mds_stores")])
        XCTAssertEqual(LsofHolders.parse(""), [])
        XCTAssertEqual(LsofHolders.parse("garbage\nc-orphan\n"), [])
    }

    func testNamesExcludeOurPidAndDuplicates() {
        let me = getpid()
        let holders: [LsofHolders.Holder] = [.init(pid: me, command: "xctest"), .init(pid: 7, command: "mds"),
                                             .init(pid: 8, command: "mds"), .init(pid: 9, command: "Preview")]
        XCTAssertEqual(LsofHolders.names(holders, excluding: me), ["mds", "Preview"])
        XCTAssertTrue(LsofHolders.onlyHeld(by: me, [.init(pid: me, command: "xctest")]))
        XCTAssertFalse(LsofHolders.onlyHeld(by: me, holders))
        XCTAssertFalse(LsofHolders.onlyHeld(by: me, []), "nobody holds it: not 'only us'")
    }
}

final class WorkspaceVolumeEventsTests: XCTestCase {
    func testMapsWorkspaceNotificationsToVolumeEvents() {
        let url = URL(filePath: "/Volumes/USB", directoryHint: .isDirectory)
        let info: [AnyHashable: Any] = [WorkspaceVolumeEvents.volumeURLKey: url]
        XCTAssertEqual(WorkspaceVolumeEvents.event(for: WorkspaceVolumeEvents.didMount, userInfo: info), .didMount(url))
        XCTAssertEqual(WorkspaceVolumeEvents.event(for: WorkspaceVolumeEvents.willUnmount, userInfo: info), .willUnmount(url))
        XCTAssertEqual(WorkspaceVolumeEvents.event(for: WorkspaceVolumeEvents.didUnmount, userInfo: info), .didUnmount(url))
        XCTAssertEqual(WorkspaceVolumeEvents.event(for: WorkspaceVolumeEvents.didRename, userInfo: info), .didRename(url))
        XCTAssertNil(WorkspaceVolumeEvents.event(for: WorkspaceVolumeEvents.didMount, userInfo: [:]))
        XCTAssertNil(WorkspaceVolumeEvents.event(for: Notification.Name("other"), userInfo: info))
    }
}

/// Real ejects, only of disk images this test created and mounted (-nobrowse) inside its own sandbox.
@MainActor
final class WorkspaceEjectorTests: XCTestCase {
    private var sandbox: Sandbox!
    private var lanes: LanePool!
    private var tokens: [ObserverToken] = []

    override func setUp() async throws {
        try XCTSkipUnless(DiskImage.isAvailable, "hdiutil not available")
        sandbox = try Sandbox()
        lanes = LanePool()
    }

    override func tearDown() async throws {
        tokens.forEach { $0.cancel() }
        tokens = []
        sandbox?.destroy()   // detaches any image still attached, then deletes only the sandbox root
        sandbox = nil
        lanes = nil
    }

    private func mountPath(of path: String) -> String? {
        var sfs = statfs()
        guard statfs(path, &sfs) == 0 else { return nil }
        return withUnsafeBytes(of: &sfs.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    private func isMounted(_ image: DiskImage) -> Bool {
        let path = image.mountPoint.path(percentEncoded: false)
        let canonical = { (p: String) in p.hasPrefix("/private/") ? String(p.dropFirst("/private".count)) : p }
        let trimmed = { (p: String) in p.count > 1 && p.hasSuffix("/") ? String(p.dropLast()) : p }
        return mountPath(of: path).map { canonical(trimmed($0)) } == canonical(trimmed(path))
    }

    private struct NotOurImage: Error, CustomStringConvertible { let description: String }

    /// Throws (stopping the test) unless the image really is mounted at its sandbox mount point.
    private func image() throws -> DiskImage {
        let image = try DiskImage.create(in: sandbox, format: .hfsPlus, sizeMB: 16, volumeName: "MACXEJECT")
        guard isMounted(image) else { throw NotOurImage(description: "image not mounted at \(image.mountPoint.path)") }
        try sandbox.createFile(image.relativeMountPath + "/held.txt")
        return image
    }

    /// The volume a test is about to eject must be the test's own image: same mount point (inside the sandbox) and
    /// the same file system as the image's mount point. Anything else — e.g. the containing data volume after a
    /// failed mount — throws before eject is called.
    private func ourVolume(_ volumes: Volumes, _ image: DiskImage) throws -> VolumeInfo {
        guard isMounted(image) else { throw NotOurImage(description: "image no longer mounted") }
        let info = try XCTUnwrap(volumes.volume(for: image.mountPoint.appending(path: "held.txt")))
        let key = { (url: URL) in ChangeBus.key(for: url) }
        guard key(info.mountPoint) == key(image.mountPoint), sandbox.contains(info.mountPoint) else {
            throw NotOurImage(description: "volume for the image path is \(info.mountPoint.path), not the test image")
        }
        var ours = statfs(), theirs = statfs()
        guard statfs(image.mountPoint.path(percentEncoded: false), &ours) == 0,
              statfs(info.mountPoint.path(percentEncoded: false), &theirs) == 0,
              ours.f_fsid.val.0 == theirs.f_fsid.val.0, ours.f_fsid.val.1 == theirs.f_fsid.val.1 else {
            throw NotOurImage(description: "file system at \(info.mountPoint.path) is not the test image's")
        }
        return info
    }

    private func ejectError(_ ejector: any Ejecting, _ url: URL) async -> EjectError? {
        do throws(EjectError) {
            try await ejector.eject(url)
            return nil
        } catch {
            return error
        }
    }

    func testEjectsAnIdleSandboxImage() async throws {
        let image = try image()
        let error = await ejectError(WorkspaceEjector(lanes: lanes), image.mountPoint)
        XCTAssertNil(error)
        XCTAssertFalse(isMounted(image))
    }

    func testRefusesAPathThatIsNotAMountPoint() async throws {
        let image = try image()
        let inside = try sandbox.createDirectory(image.relativeMountPath + "/sub")
        let error = await ejectError(WorkspaceEjector(lanes: lanes), inside)
        XCTAssertEqual(error, .failed(code: EINVAL, message: ""), "never ejects the volume that merely contains a path")
        XCTAssertTrue(isMounted(image))
    }

    func testAnOpenFileOfOurOwnMakesItBusyAndOnlyOurs() async throws {
        let image = try image()
        let fd = open(image.mountPoint.appending(path: "held.txt").path(percentEncoded: false), O_RDONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        let ejector = WorkspaceEjector(lanes: lanes)
        let error = await ejectError(ejector, image.mountPoint)
        guard case .busy(let names) = error else { return XCTFail("expected busy, got \(String(describing: error))") }
        XCTAssertEqual(names, [], "our own PID is excluded")
        let onlyOwn = await ejector.onlyOwnProcessHolds(image.mountPoint, timeout: .seconds(10))
        XCTAssertTrue(onlyOwn)
        let blocking = await ejector.blockingProcesses(image.mountPoint, timeout: .seconds(10))
        XCTAssertEqual(blocking, [])
        XCTAssertTrue(isMounted(image))
    }

    func testGuardRefusesTheContainingVolumeWhenTheImageIsGone() async throws {
        let image = try image()
        try image.detach()
        let volumes = Volumes(lanes: lanes, events: nil)
        await volumes.refresh()
        let containing = try XCTUnwrap(volumes.volume(for: image.mountPoint))
        XCTAssertFalse(sandbox.contains(containing.mountPoint), "the lookup now lands on a real system volume")
        XCTAssertThrowsError(try ourVolume(volumes, image), "never handed to eject")
    }

    func testCoordinatorRetriesAfterReleasingOurOwnHold() async throws {
        let image = try image()
        let volumes = Volumes(lanes: lanes, events: nil)
        await volumes.refresh()
        let info = try ourVolume(volumes, image)
        let fd = open(image.mountPoint.appending(path: "held.txt").path(percentEncoded: false), O_RDONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var releases = 0
        var closed = false
        tokens.append(volumes.addReleaseHandler { _ in
            releases += 1
            if releases == 2, !closed { close(fd); closed = true }   // a reader that only lets go on the second release
        })
        let coordinator = EjectCoordinator(volumes: volumes, ejector: WorkspaceEjector(lanes: lanes))
        var failure: EjectError?
        do throws(EjectError) { try await coordinator.eject(info) } catch { failure = error }
        if !closed { close(fd) }
        XCTAssertNil(failure)
        XCTAssertEqual(releases, 2)
        XCTAssertFalse(isMounted(image))
        XCTAssertFalse(volumes.list.contains { $0.id == info.id })
    }

    func testAnotherProcessHoldingItIsNamed() async throws {
        let image = try image()
        let sleeper = Process()
        sleeper.executableURL = URL(filePath: "/bin/sleep")
        sleeper.arguments = ["60"]
        sleeper.currentDirectoryURL = image.mountPoint
        try sleeper.run()
        defer { sleeper.terminate(); sleeper.waitUntilExit() }
        let volumes = Volumes(lanes: lanes, events: nil)
        await volumes.refresh()
        let info = try ourVolume(volumes, image)
        var releases = 0
        tokens.append(volumes.addReleaseHandler { _ in releases += 1 })
        let coordinator = EjectCoordinator(volumes: volumes, ejector: WorkspaceEjector(lanes: lanes))
        var failure: EjectError?
        do throws(EjectError) { try await coordinator.eject(info) } catch { failure = error }
        XCTAssertEqual(failure, .busy(processes: ["sleep"]))
        XCTAssertEqual(releases, 1, "no retry when someone else holds it")
        XCTAssertTrue(isMounted(image))
    }
}
