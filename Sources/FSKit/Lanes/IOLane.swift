import Foundation
import Synchronization

public struct LaneID: Hashable, Sendable, CustomStringConvertible {
    public let raw: UInt64
    public var description: String { "lane\(raw)" }
}

public enum LaneClass: Sendable, Hashable { case read, fileOp }

/// One dedicated Thread with a serial FIFO of work items (§4.2). Never the cooperative pool or a GCD
/// global queue. A poisoned lane accepts no more work; its thread exits once its current item returns.
final class IOLane: Sendable {
    struct Item: Sendable {
        let job: LaneJob
        let run: @Sendable () -> Void
        let fail: @Sendable (any Error) -> Void
    }

    private struct State {
        var queue: [Item] = []
        var running: LaneJob?
        var poisoned = false
        var stopped = false
    }

    let id: LaneID
    let volume: VolumeID
    let laneClass: LaneClass
    private let state = Mutex(State())
    private let wakeup = DispatchSemaphore(value: 0)

    init(id: LaneID, volume: VolumeID, laneClass: LaneClass) {
        self.id = id
        self.volume = volume
        self.laneClass = laneClass
        let thread = Thread { [self] in self.loop() }
        thread.name = "macx.lane.\(laneClass).\(volume.raw).\(id.raw)"
        thread.qualityOfService = laneClass == .read ? .userInitiated : .utility
        thread.stackSize = 1 << 20
        thread.start()
    }

    /// Number of queued + running items.
    var load: Int { state.withLock { $0.queue.count + ($0.running == nil ? 0 : 1) } }
    var runningJob: LaneJob? { state.withLock { $0.running } }

    /// False if the lane is poisoned or stopped (caller picks another lane).
    func submit(_ item: Item) -> Bool {
        let accepted = state.withLock { s -> Bool in
            guard !s.poisoned, !s.stopped else { return false }
            s.queue.append(item)
            return true
        }
        if accepted { wakeup.signal() }
        return accepted
    }

    /// Removes a not-yet-started job (cancellation before start). Nil if it already started or isn't here.
    func withdraw(_ job: LaneJob) -> Item? {
        state.withLock { s in
            guard let i = s.queue.firstIndex(where: { $0.job === job }) else { return nil }
            return s.queue.remove(at: i)
        }
    }

    /// Marks the lane poisoned and hands back the items that had not started, for re-dispatch.
    func poison() -> [Item] {
        let drained = state.withLock { s -> [Item] in
            s.poisoned = true
            defer { s.queue.removeAll() }
            return s.queue
        }
        wakeup.signal()
        return drained
    }

    /// Lets an idle, healthy lane's thread exit (pool shutdown).
    func stop() {
        state.withLock { $0.stopped = true }
        wakeup.signal()
    }

    private func loop() {
        while true {
            wakeup.wait()
            let next = state.withLock { s -> Item? in
                if s.poisoned || (s.stopped && s.queue.isEmpty) { return nil }
                guard !s.queue.isEmpty else { return nil }
                let item = s.queue.removeFirst()
                s.running = item.job
                return item
            }
            guard let item = next else {
                if state.withLock({ $0.poisoned || $0.stopped }) { return }
                continue
            }
            item.job.laneID.store(id.raw, ordering: .relaxed)
            item.job.beat()
            item.run()
            let exit = state.withLock { s -> Bool in
                s.running = nil
                return s.poisoned
            }
            if exit { return }   // poisoned while blocked: never reused
        }
    }
}
