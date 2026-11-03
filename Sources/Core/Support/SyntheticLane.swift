import Foundation
import MacxFS
import Synchronization

extension LanePool {
    /// For single blocking system calls keyed on a synthetic lane volume (LaunchServices, bookmark resolution on
    /// VolumeID.unknown). Like `perform`, a call that stalls poisons its lane (so a truly hung call never holds the
    /// pool), but when a stalled call does return late — a cold LaunchServices query, a slow share that answered —
    /// the synthetic volume is reset. Without this, poisonCap slow-but-finite calls would mark the synthetic volume
    /// unresponsive forever, since nothing remounts it.
    func performRecovering<T: Sendable>(on volume: VolumeID, _ laneClass: LaneClass = .read,
                                        _ work: @escaping @Sendable (LaneContext) throws -> T) async throws -> T {
        let stalled = Mutex(false)
        let result: T
        do {
            result = try await perform(on: volume, laneClass, onStall: { notice in
                if notice == .stalled { stalled.withLock { $0 = true } }
            }, work)
        } catch {
            if stalled.withLock({ $0 }) { resetVolume(volume) }
            throw error
        }
        if stalled.withLock({ $0 }) { resetVolume(volume) }
        return result
    }
}
