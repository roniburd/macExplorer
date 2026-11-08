import Darwin
import Foundation

/// Lane-side read function; BulkReader.read in production, a fake in tests (@testable init).
/// Untyped `throws` on purpose: converting a typed-throws closure to LanePool's `throws` work closure
/// produced corrupted error payloads with Swift 6.4 (verified 2026-11-02). Throw only ReadFailure.
typealias ReadImplementation = @Sendable (URL, Generation, ReadOptions, TypeRegistry, LaneContext, (Batch) -> Bool) throws -> ReadSummary

/// One per volume (§4.2). Holds only coordination state; every blocking call runs on that volume's read lanes.
public actor DirectoryReader {
    public nonisolated let volume: VolumeID
    private let lanes: LanePool
    private let types: TypeRegistry
    private let implementation: ReadImplementation
    private var inFlight: [UUID: Task<Void, Never>] = [:]
    private var idleWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// How `cancelAll` waits out its timeout: `Task.sleep` in the app; a test seam controls it (@testable init).
    private let idleTimeoutSleep: @Sendable (Duration) async -> Void

    public init(volume: VolumeID, lanes: LanePool, types: TypeRegistry = .shared) {
        self.init(volume: volume, lanes: lanes, types: types) { dir, gen, options, types, ctx, emit in
            try BulkReader.read(dir, generation: gen, options: options, types: types, context: ctx, emit: emit)
        }
    }

    init(volume: VolumeID, lanes: LanePool, types: TypeRegistry, implementation: @escaping ReadImplementation,
         idleTimeoutSleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.volume = volume
        self.lanes = lanes
        self.types = types
        self.idleTimeoutSleep = idleTimeoutSleep
        self.implementation = implementation
    }

    /// Test seam: reads currently running.
    var inFlightCount: Int { inFlight.count }

    /// One stream per read; ends after .completed or .failed (or when the consumer cancels iteration,
    /// which cancels the lane work at the next batch boundary). A cancelled read (consumer gone or
    /// cancelAll) never yields .completed: the stream just finishes.
    public func read(_ directory: URL, generation: Generation, options: ReadOptions = ReadOptions()) -> AsyncStream<ReadEvent> {
        let (stream, continuation) = AsyncStream<ReadEvent>.makeStream(bufferingPolicy: .unbounded)
        let id = UUID()
        let lanes = self.lanes, types = self.types, implementation = self.implementation, volume = self.volume
        let signpost = PerfSignposts.signposter.beginInterval(PerfSignposts.enumerate)
        let task = Task {
            let policy: StallPolicy = options.permissionPending ? .awaitingPermission : .poison
            do {
                let summary = try await lanes.perform(on: volume, .read, stallPolicy: policy, onStall: { notice in
                    switch notice {
                    case .stalled: continuation.yield(.stalled)
                    case .waitingForPermission: continuation.yield(.waitingForPermission)
                    case .resumed: continuation.yield(.resumed)
                    }
                }) { ctx -> ReadSummary in
                    try implementation(directory, generation, options, types, ctx) { batch in
                        if ctx.isCancelled { return false }
                        continuation.yield(.batch(batch))
                        return true
                    }
                }
                // cancelAll()/consumer cancel: the reader stopped early with a partial count. Not a full listing.
                if Task.isCancelled { throw LaneError.cancelled }
                continuation.yield(.completed(summary))
            } catch let failure as ReadFailure {
                continuation.yield(.failed(failure))
            } catch LaneError.volumeUnresponsive {
                continuation.yield(.failed(ReadFailure(code: ETIMEDOUT, stage: .unresponsiveVolume)))
            } catch {
                // LaneError.cancelled: the consumer went away; nothing to report.
            }
            PerfSignposts.signposter.endInterval(PerfSignposts.enumerate, signpost)
            continuation.finish()
            self.finished(id)
        }
        inFlight[id] = task
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Single-shot stat of names (watcher incremental path). Runs on a read lane.
    public func readItems(_ names: [String], in directory: URL, generation: Generation) async throws -> ItemReadResult {
        let types = self.types
        return try await lanes.perform(on: volume, .read) { ctx in
            try ItemReader.read(names: names, in: directory, generation: generation, types: types, context: ctx)
        }
    }

    /// Volumes.release: cancel in-flight reads, wait ≤ 1 s for their fds to close.
    public func cancelAll() async {
        for task in inFlight.values { task.cancel() }
        await waitForIdle(timeout: .seconds(1))
    }

    private func waitForIdle(timeout: Duration) async {
        guard !inFlight.isEmpty else { return }
        let id = UUID()
        let sleep = idleTimeoutSleep
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            idleWaiters[id] = c
            Task {
                await sleep(timeout)
                self.resumeWaiter(id)
            }
        }
    }

    private func resumeWaiter(_ id: UUID) { idleWaiters.removeValue(forKey: id)?.resume() }

    private func finished(_ id: UUID) {
        inFlight[id] = nil
        if inFlight.isEmpty {
            let waiters = idleWaiters.values
            idleWaiters.removeAll()
            for w in waiters { w.resume() }
        }
    }
}
