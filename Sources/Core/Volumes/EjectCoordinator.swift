import Foundation
import MacxFS

public enum EjectError: Error, Sendable, Equatable {
    case busy(processes: [String])     // names from lsof, excluding our own PID
    case failed(code: Int32, message: String)
}

public protocol Ejecting: Sendable {
    func eject(_ mountPoint: URL) async throws(EjectError)
    func blockingProcesses(_ mountPoint: URL, timeout: Duration) async -> [String]   // ours excluded
    func onlyOwnProcessHolds(_ mountPoint: URL, timeout: Duration) async -> Bool
}

/// §5.9 Eject: `Volumes.release` (cancel reads, stop watchers, pause jobs, move windows home), then the ejector.
/// A busy volume held only by this process is released once more and retried once; otherwise the busy error
/// names the blocking processes. A successful eject rescans the volume list at once.
@MainActor
public final class EjectCoordinator {
    /// How long lsof may run when diagnosing a busy volume.
    public var diagnosisTimeout: Duration = .seconds(3)

    private let volumes: Volumes
    private let ejector: any Ejecting

    public init(volumes: Volumes, ejector: any Ejecting) {
        self.volumes = volumes
        self.ejector = ejector
    }

    /// release → eject; if busy and only we hold it, release once more and retry once.
    public func eject(_ volume: VolumeInfo) async throws(EjectError) {
        let mountPoint = volume.mountPoint
        await volumes.release(volume.id)
        do {
            try await ejector.eject(mountPoint)
        } catch {
            guard case .busy(let names) = error else { throw error }
            guard await ejector.onlyOwnProcessHolds(mountPoint, timeout: diagnosisTimeout) else {
                if !names.isEmpty { throw error }
                throw .busy(processes: await ejector.blockingProcesses(mountPoint, timeout: diagnosisTimeout))
            }
            await volumes.release(volume.id)
            try await ejector.eject(mountPoint)
        }
        await volumes.refresh()
    }
}
