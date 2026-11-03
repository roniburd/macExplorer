@testable import Core
import Darwin
import Foundation
import MacxFixtures
@testable import MacxFS
import Synchronization
import XCTest

/// One fake volume at "/" so every sandbox path maps to it, with the capabilities a test asks for, plus any
/// extra fake volumes a test mounts at sandbox paths (and later "unmounts").
final class RootVolumeScanner: VolumeScanning {
    let caps: VolumeCapabilities
    private let extra = Mutex<[VolumeInfo]>([])
    init(_ caps: VolumeCapabilities) { self.caps = caps }
    func scan() throws -> [VolumeInfo] {
        [VolumeInfo(id: VolumeID(raw: "test-root"), mountPoint: URL(filePath: "/", directoryHint: .isDirectory), name: "Root",
                    format: "APFS", isBoot: true, isInternal: true, isRemovable: false, isEjectable: false, isLocal: true,
                    isReadOnly: false, isBrowsable: true, totalCapacity: nil, capabilities: caps)] + extra.withLock { $0 }
    }
    func availableCapacity(of mountPoint: URL) -> Int64? { nil }

    func addVolume(_ raw: String, at mountPoint: URL) {
        let info = VolumeInfo(id: VolumeID(raw: raw), mountPoint: mountPoint, name: raw, format: "APFS", isBoot: false,
                              isInternal: false, isRemovable: true, isEjectable: true, isLocal: true, isReadOnly: false,
                              isBrowsable: true, totalCapacity: nil, capabilities: caps)
        extra.withLock { $0.append(info) }
    }

    func removeVolume(_ raw: String) { extra.withLock { $0.removeAll { $0.id == VolumeID(raw: raw) } } }
}

/// Frames advance only when the test calls tick() (counts resets per frame).
final class ManualFramePacer: FramePacer {
    private let waiters = Mutex<[CheckedContinuation<Void, Never>]>([])
    private let waitingCount = Mutex(0)

    func nextFrame() async {
        await withCheckedContinuation { c in
            waiters.withLock { $0.append(c) }
            waitingCount.withLock { $0 += 1 }
        }
    }

    var waiting: Int { waiters.withLock { $0.count } }

    func tick() {
        let all = waiters.withLock { w -> [CheckedContinuation<Void, Never>] in defer { w.removeAll() }; return w }
        for c in all { c.resume() }
    }
}

/// Records start/stop and the event ID it was created with; `send` plays the FSEvents side.
final class RecordingWatcher: ContentWatching {
    let since: UInt64
    let log = Mutex<[String]>([])
    let send: @Sendable (WatchEvent) -> Void
    init(since: UInt64, send: @escaping @Sendable (WatchEvent) -> Void = { _ in }) {
        self.since = since
        self.send = send
    }
    func start() { log.withLock { $0.append("start") } }
    func stop() { log.withLock { $0.append("stop") } }
    var lastEventID: UInt64 { since }
    var events: [String] { log.withLock { $0 } }
}

/// A scripted read: the test yields ReadEvents into it.
@MainActor
final class ScriptedReads {
    struct Read {
        let directory: URL
        let generation: Generation
        let options: ReadOptions
        let continuation: AsyncStream<ReadEvent>.Continuation
    }
    private(set) var reads: [Read] = []
    var last: Read { reads[reads.count - 1] }

    func source() -> FolderModel.ReadSource {
        { [weak self] directory, generation, options in
            let (stream, continuation) = AsyncStream<ReadEvent>.makeStream()
            self?.reads.append(Read(directory: directory, generation: generation, options: options, continuation: continuation))
            return stream
        }
    }
}

/// Builds Batches without touching the disk.
enum TestBatch {
    struct Item {
        var name: String
        var id: UInt64
        var kind: Kind = .file
        var size: Int64 = 0
        var hidden = false
    }

    static func make(_ generation: Generation, _ items: [Item]) -> Batch {
        var batch = Batch(generation: generation)
        for item in items {
            var flags: EntryFlags = item.hidden ? [.bsdHidden] : []
            if item.name.hasPrefix(".") { flags.insert(.dotName) }
            let typeIndex = item.kind == .directory ? TypeRegistry.folderIndex : TypeRegistry.dataIndex
            let e = Entry(rowID: item.id, fileID: item.id, size: item.size, allocSize: 0, mtime: 0, ctime: 0,
                          nameOffset: 0, nameLen: 0, kind: item.kind, flags: flags, typeIndex: typeIndex)
            Array(item.name.utf8).withUnsafeBufferPointer { batch.append(e, nameBytes: $0) }
        }
        return batch
    }

    static func files(_ generation: Generation, _ names: [String], firstID: UInt64 = 1) -> Batch {
        make(generation, names.enumerated().map { Item(name: $0.element, id: firstID + UInt64($0.offset)) })
    }
}

/// Everything a FolderModel test needs: a sandbox, a fake root volume, lanes, readers, a bus, recorded
/// watchers and permission outcomes. All writes stay inside `sandbox.root`.
@MainActor
final class FolderTestWorld {
    let sandbox: Sandbox
    let lanes: LanePool
    let volumes: Volumes
    let readers: DirectoryReaders
    let bus = ChangeBus()
    var pacer: any FramePacer = TimerFramePacer(interval: .milliseconds(1))
    /// true: models get a real FSEvents Watcher (50 ms latency) instead of a RecordingWatcher.
    var realWatcher = false
    let scanner: RootVolumeScanner
    var pending: Set<String> = []
    private(set) var outcomes: [(String, Bool)] = []
    private(set) var watchers: [RecordingWatcher] = []
    private var models: [FolderModel] = []
    private var tokens: [ObserverToken] = []

    static func make(_ testCase: XCTestCase,
                     caps: VolumeCapabilities = VolumeCapabilities(idStable: true, renameExcl: true, clone: true, caseSensitive: false))
        async throws -> FolderTestWorld {
        let world = try FolderTestWorld(caps: caps)
        testCase.addTeardownBlock { @MainActor in world.tearDown() }
        await world.volumes.start()
        return world
    }

    private init(caps: VolumeCapabilities) throws {
        sandbox = try Sandbox(prefix: "macx-tests")
        lanes = LanePool()
        scanner = RootVolumeScanner(caps)
        volumes = Volumes(lanes: lanes, scanner: scanner, events: nil)
        readers = DirectoryReaders(lanes: lanes, mountTable: volumes.mountTableStore)
    }

    private func tearDown() {
        for m in models { m.close() }
        tokens.removeAll()
        sandbox.destroy()
    }

    var context: FolderContext {
        FolderContext(readers: readers, lanes: lanes, volumes: volumes, changeBus: bus, pacer: pacer,
                      makeWatcher: { [weak self] directory, since, handler in
                          if self?.realWatcher == true {
                              return Watcher(directory: directory, since: since, latency: .milliseconds(50), handler: handler)
                          }
                          let w = RecordingWatcher(since: since, send: handler)
                          self?.watchers.append(w)
                          return w
                      },
                      permissionPending: { [weak self] url in self?.pending.contains(url.lastPathComponent) ?? false },
                      recordPermissionOutcome: { [weak self] url, granted in self?.outcomes.append((url.lastPathComponent, granted)) },
                      home: sandbox.root)
    }

    var outcomeLog: [String] { outcomes.map { "\($0.0):\($0.1)" } }

    func url(_ relative: String) -> URL { sandbox.url(relative) }

    @discardableResult
    func file(_ relative: String, _ contents: String = "x") throws -> URL {
        try sandbox.createFile(relative, contents: Data(contents.utf8))
    }

    @discardableResult
    func dir(_ relative: String) throws -> URL { try sandbox.createDirectory(relative) }

    func setHidden(_ relative: String) throws {
        guard chflags(sandbox.url(relative).path, UInt32(UF_HIDDEN)) == 0 else { throw POSIXError(.init(rawValue: errno)!) }
    }

    func remove(_ relative: String) throws {
        guard unlink(sandbox.url(relative).path) == 0 else { throw POSIXError(.init(rawValue: errno)!) }
    }

    func rename(_ from: String, _ to: String) throws {
        guard Darwin.rename(sandbox.url(from).path, sandbox.url(to).path) == 0 else { throw POSIXError(.init(rawValue: errno)!) }
    }

    /// An unstarted model, closed in teardown.
    func model(_ directory: URL, query: ViewQuery = ViewQuery()) -> FolderModel {
        let m = FolderModel(directory: directory, context: context, query: query)
        models.append(m)
        return m
    }

    /// A started model whose initial read completed.
    func open(_ relative: String, query: ViewQuery = ViewQuery()) async throws -> FolderModel {
        let m = model(url(relative), query: query)
        m.start()
        try await waitUntil("\(relative) complete") { m.state == .complete }
        return m
    }

    func keep(_ token: ObserverToken) { tokens.append(token) }

    func waitUntil(_ what: String, timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline { throw WaitTimeout(what: what) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Lets queued main-actor work run.
    func settle(_ duration: Duration = .milliseconds(50)) async {
        try? await Task.sleep(for: duration)
    }
}

struct WaitTimeout: Error, CustomStringConvertible {
    let what: String
    var description: String { "timed out waiting for: \(what)" }
}

/// Records a model's events.
@MainActor
final class FolderEventLog {
    private(set) var events: [FolderEvent] = []
    private var token: ObserverToken?

    init(_ model: FolderModel) {
        token = model.observe { [weak self] in self?.events.append($0) }
    }

    func clear() { events.removeAll() }

    var resets: Int { changeSets.filter { $0.changes.contains(.reset) }.count }
    var changeSets: [ChangeSet] { events.compactMap { if case .changes(let c) = $0 { c } else { nil } } }
    var states: [FolderState] { events.compactMap { if case .state(let s) = $0 { s } else { nil } } }
    var selections: [Selection] { events.compactMap { if case .selection(let s) = $0 { s } else { nil } } }
    var renames: [Int] { events.compactMap { if case .beginRename(let r) = $0 { r } else { nil } } }
    var queries: [ViewQuery] { events.compactMap { if case .query(let q) = $0 { q } else { nil } } }
    var relocations: [(URL, RelocationReason)] {
        events.compactMap { if case .relocate(let url, let reason) = $0 { (url, reason) } else { nil } }
    }
}

extension FolderModel {
    var rowNames: [String] { (0..<rowCount).map { name(atRow: $0) } }
    var selectedNames: [String] { selectedURLs.map(\.lastPathComponent) }
}
