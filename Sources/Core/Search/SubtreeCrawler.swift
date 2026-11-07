import Foundation
import MacxFS

/// "Subfolders, by name" engine (§11 Phase 3): breadth-first over the root's subtree with at most
/// `maxConcurrentReads` directory reads in flight on the root volume's `.scan` lanes, each under
/// `withNoMaterialization`. Never follows symlinks or aliases, never crosses mount points, skips packages and
/// hidden items unless enabled, skips blocked (TCC) prefixes without opening them. Name terms match the on-disk
/// name or the Finder display name (hidden extensions), as the in-folder filter does. Localized folder names are
/// not available without materializing metadata, so they are not matched here (accepted engine difference).
public enum SubtreeCrawler {
    /// Synchronous directory read (lane only). Returns a Result: typed-throws closures must not cross
    /// `LanePool.perform` (S1 Contract note 7).
    typealias DirectoryRead = @Sendable (URL, Generation, ReadOptions, TypeRegistry, LaneContext, (Batch) -> Bool)
        -> Result<ReadSummary, ReadFailure>

    static let defaultRead: DirectoryRead = { url, generation, options, types, context, emit in
        do throws(ReadFailure) {
            return .success(try BulkReader.read(url, generation: generation, options: options, types: types,
                                                context: context, emit: emit))
        } catch {
            return .failure(error)
        }
    }

    public static func crawl(root: URL, criteria: SearchCriteria, options: CrawlOptions, permissions: CrawlPermissions,
                             generation: Generation, lanes: LanePool, mountTable: MountTableStore,
                             types: TypeRegistry = .shared) -> AsyncStream<SearchEvent> {
        crawl(root: root, criteria: criteria, options: options, permissions: permissions, generation: generation,
              lanes: lanes, mountTable: mountTable, types: types, read: defaultRead)
    }

    static func crawl(root: URL, criteria: SearchCriteria, options: CrawlOptions, permissions: CrawlPermissions,
                      generation: Generation, lanes: LanePool, mountTable: MountTableStore,
                      types: TypeRegistry, read: @escaping DirectoryRead) -> AsyncStream<SearchEvent> {
        let (stream, continuation) = AsyncStream<SearchEvent>.makeStream(bufferingPolicy: .unbounded)
        let run = CrawlRun(root: root, criteria: criteria, options: options, permissions: permissions,
                           generation: generation, lanes: lanes, mountTable: mountTable, types: types, read: read)
        let task = Task {
            await run.run(continuation)
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}

struct DirectoryOutcome: Sendable {
    enum Status: Sendable { case read, failed(ReadFailure), stalled, volumeUnresponsive, cancelled }
    var status: Status
    var matches: [Batch] = []
    var children: [Child] = []
    struct Child: Sendable { var name: String; var fileID: UInt64 }
    static let stalled = DirectoryOutcome(status: .stalled)
    static let cancelled = DirectoryOutcome(status: .cancelled)
}

struct CrawlRun: Sendable {
    let root: URL
    let criteria: SearchCriteria
    let options: CrawlOptions
    let permissions: CrawlPermissions
    let generation: Generation
    let lanes: LanePool
    let mountTable: MountTableStore
    let types: TypeRegistry
    let read: SubtreeCrawler.DirectoryRead

    /// The root's own spelling, trimmed. Not `standardizedFileURL`: on macOS 26 that also drops a leading
    /// "/private", and result parents must keep the spelling the caller (and its sandbox / history) used.
    static func standardized(_ url: URL) -> String { CrawlPermissions.trim(url.path(percentEncoded: false)) }
    static func join(_ parent: String, _ name: String) -> String { parent == "/" ? "/" + name : parent + "/" + name }

    func run(_ out: AsyncStream<SearchEvent>.Continuation) async {
        let clock = ContinuousClock()
        let start = clock.now
        let rootPath = Self.standardized(root)
        let table = mountTable.current()
        let rootVolume = table.volume(containing: rootPath)
        let volume = rootVolume?.id ?? .unknown
        let perms = permissions.relevant(forRoot: rootPath)

        var queue = [rootPath], head = 0
        var visited = Set<UInt64>()
        var scanned = 0, results = 0, skippedTotal = 0
        var skipped: [SkippedLocation] = []
        var truncated = false
        var lastProgress = start
        func skip(_ path: String, _ reason: SkipReason) {
            skippedTotal += 1
            if skipped.count < 50 { skipped.append(SkippedLocation(path: path, reason: reason)) }
        }
        /// Emits the outcome's matches (up to the cap) and queues its descendable children.
        func absorb(_ path: String, _ outcome: DirectoryOutcome) {
            let parentURL = URL(filePath: path, directoryHint: .isDirectory)
            for batch in outcome.matches where !truncated {
                var b = batch
                let room = options.maxResults - results
                if b.count > room { b = Self.prefix(b, room); truncated = true }
                if b.count > 0 { out.yield(.batch(SearchBatch(parent: parentURL, batch: b))); results += b.count }
                if results >= options.maxResults { truncated = true }
            }
            for child in outcome.children {
                let childPath = Self.join(path, child.name)
                if perms.isBlocked(childPath) { skip(childPath, .protectedLocation); continue }
                // Another volume, or a mount point of any volume: not descended. MountTable.standardize
                // on both sides, so /private/var/… and /var/… spellings compare equal.
                if let v = table.volume(containing: childPath),
                   v.id != rootVolume?.id
                    || MountTable.standardize(v.mountPoint.path(percentEncoded: false)) == MountTable.standardize(childPath) {
                    continue
                }
                if child.fileID != 0, !visited.insert(child.fileID).inserted { continue }
                queue.append(childPath)
            }
        }

        let finished: Bool = await withTaskGroup(of: (String, DirectoryOutcome).self) { group in
            var inFlight = 0
            while true {
                while inFlight < max(1, options.maxConcurrentReads), head < queue.count, !truncated {
                    let path = queue[head]
                    head += 1
                    inFlight += 1
                    group.addTask { (path, await self.readOne(path, volume: volume)) }
                }
                guard inFlight > 0, let next = await group.next() else { return true }
                let (path, outcome) = next
                inFlight -= 1
                if truncated { continue }                       // draining reads cancelled by the cap
                if Task.isCancelled { group.cancelAll(); return false }
                switch outcome.status {
                case .cancelled:
                    group.cancelAll(); return false
                case .volumeUnresponsive:
                    out.yield(.failed(.volumeUnresponsive)); group.cancelAll(); return false
                case .failed(let f):
                    if f.stage == .unresponsiveVolume { out.yield(.failed(.volumeUnresponsive)); group.cancelAll(); return false }
                    if path == rootPath { out.yield(.failed(.rootUnreadable(Reason(errno: f.code)))); group.cancelAll(); return false }
                    absorb(path, outcome)                           // batches delivered before a mid-read failure
                    switch f.code {
                    case EACCES, EPERM: skip(path, .permission(f.code))
                    case ENOENT, ENOTDIR: break                     // deleted or replaced mid-crawl: nothing to report
                    default: skip(path, .unreadable(f.code))
                    }
                case .stalled:
                    if path == rootPath { out.yield(.failed(.volumeUnresponsive)); group.cancelAll(); return false }
                    skip(path, .unresponsive)
                case .read:
                    scanned += 1
                    absorb(path, outcome)
                }
                if clock.now - lastProgress >= options.progressInterval {
                    lastProgress = clock.now
                    out.yield(.progress(SearchProgress(directoriesScanned: scanned, resultCount: results, currentPath: path)))
                }
                if truncated { group.cancelAll() }
            }
        }
        guard finished, !Task.isCancelled else { return }
        out.yield(.completed(SearchSummary(resultCount: results, directoriesScanned: scanned, skipped: skipped,
                                           skippedTotal: skippedTotal, truncated: truncated, elapsed: clock.now - start)))
    }

    static func prefix(_ batch: Batch, _ n: Int) -> Batch {
        var out = Batch(generation: batch.generation)
        batch.names.withUnsafeBufferPointer { names in
            for e in batch.entries.prefix(max(0, n)) {
                let o = Int(e.nameOffset)
                out.append(e, nameBytes: UnsafeBufferPointer(rebasing: names[o..<(o + Int(e.nameLen))]))
            }
        }
        return out
    }

    /// One directory on a scan lane. A watchdog stall resolves the wait immediately as `.stalled`.
    func readOne(_ path: String, volume: VolumeID) async -> DirectoryOutcome {
        let box = OneShotValue<DirectoryOutcome>()
        let run = self
        let inner = Task {
            do {
                let outcome = try await run.lanes.perform(on: volume, .scan, onStall: { notice in
                    if notice == .stalled { box.resume(.stalled) }
                }) { context in
                    run.readDirectory(path, context: context)
                }
                box.resume(outcome)
            } catch LaneError.volumeUnresponsive(_) {
                box.resume(DirectoryOutcome(status: .volumeUnresponsive))
            } catch {
                box.resume(.cancelled)
            }
        }
        return await withTaskCancellationHandler {
            await box.value()
        } onCancel: {
            inner.cancel()
            box.resume(.cancelled)
        }
    }

    /// Lane work: read, match, collect descendable children. Synchronous; no suspension points.
    func readDirectory(_ path: String, context: LaneContext) -> DirectoryOutcome {
        var outcome = DirectoryOutcome(status: .read)
        var matcher = CriteriaMatcher(criteria, types: types)
        var readOptions = ReadOptions()
        readOptions.noMaterialization = true
        let url = URL(filePath: path, directoryHint: .isDirectory)
        let result = withNoMaterialization {
            read(url, generation, readOptions, types, context) { batch in
                var hits = Batch(generation: generation)
                batch.names.withUnsafeBufferPointer { names in
                    for e in batch.entries {
                        if e.flags.isHidden && !options.includeHidden { continue }
                        let o = Int(e.nameOffset)
                        let bytes = UnsafeBufferPointer(rebasing: names[o..<(o + Int(e.nameLen))])
                        let name = String(decoding: bytes, as: UTF8.self)
                        let descend = e.kind == .directory || (e.kind == .package && options.includePackages)
                        if descend && !e.flags.contains(.dataless) {
                            outcome.children.append(.init(name: name, fileID: e.fileID))
                        }
                        let folded = SortKeys.searchFold(name)
                        let display = !options.showAllExtensions && (e.kind == .package || e.flags.contains(.extensionHidden))
                            ? DisplayName.make(name: name, kind: e.kind, flags: e.flags, localizedStem: nil, showAllExtensions: false)
                            : name
                        let hit: Bool
                        if display != name {
                            hit = SortKeys.searchFold(display).withUnsafeBytes { shown in
                                folded.withUnsafeBytes { matcher.matches(e, foldedName: shown, foldedFileName: $0) }
                            }
                        } else {
                            hit = folded.withUnsafeBytes { matcher.matches(e, foldedName: $0) }
                        }
                        if hit { hits.append(e, nameBytes: bytes) }
                    }
                }
                if hits.count > 0 { outcome.matches.append(hits) }
                context.heartbeat()
                return !context.isCancelled
            }
        }
        if case .failure(let failure) = result { outcome.status = .failed(failure) }
        if context.isCancelled { outcome.status = .cancelled }
        return outcome
    }
}
