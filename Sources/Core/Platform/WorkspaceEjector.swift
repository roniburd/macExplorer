import AppKit
import Darwin
import Foundation
import MacxFS

/// `Ejecting` through `NSWorkspace.unmountAndEjectDevice(at:)` (§5.9), with lsof-based busy diagnosis. It refuses
/// any URL that is not itself a mount point, so it can never eject the volume that merely contains a path.
public struct WorkspaceEjector: Ejecting {
    private let lanes: LanePool

    public init(lanes: LanePool) { self.lanes = lanes }

    private enum Outcome: Sendable { case ejected, notMountPoint, error(domain: String, code: Int, message: String) }

    public func eject(_ mountPoint: URL) async throws(EjectError) {
        let path = Self.path(mountPoint)
        let outcome: Outcome
        do {
            // unmountAndEjectDevice is one blocking call with no chance to heartbeat; never poison a lane for it.
            outcome = try await lanes.perform(on: Self.lane(path), .fileOp, stallPolicy: .awaitingPermission) { _ in
                assertOffMain()
                guard Self.isMountPoint(path) else { return .notMountPoint }
                do {
                    try NSWorkspace.shared.unmountAndEjectDevice(at: URL(filePath: path, directoryHint: .isDirectory))
                    return .ejected
                } catch {
                    let ns = error as NSError
                    return .error(domain: ns.domain, code: ns.code, message: ns.localizedDescription)
                }
            }
        } catch {
            throw .failed(code: EIO, message: "")
        }
        switch outcome {
        case .ejected:
            return
        case .notMountPoint:
            throw .failed(code: EINVAL, message: "")
        case .error(let domain, let code, let message):
            if Self.isBusy(domain: domain, code: code) {
                throw .busy(processes: await blockingProcesses(mountPoint, timeout: .seconds(3)))
            }
            throw .failed(code: Int32(truncatingIfNeeded: code), message: message)
        }
    }

    public func blockingProcesses(_ mountPoint: URL, timeout: Duration) async -> [String] {
        LsofHolders.names(await holders(mountPoint, timeout: timeout), excluding: getpid())
    }

    public func onlyOwnProcessHolds(_ mountPoint: URL, timeout: Duration) async -> Bool {
        LsofHolders.onlyHeld(by: getpid(), await holders(mountPoint, timeout: timeout))
    }

    private func holders(_ mountPoint: URL, timeout: Duration) async -> [LsofHolders.Holder] {
        let path = Self.path(mountPoint)
        return (try? await lanes.perform(on: Self.lane(path), .read) { lane in
            Self.isMountPoint(path) ? LsofHolders.holders(of: URL(filePath: path), timeout: timeout, lane: lane) : []
        }) ?? []
    }

    // MARK: helpers

    static func isBusy(domain: String, code: Int) -> Bool {
        switch domain {
        case NSPOSIXErrorDomain: return code == Int(EBUSY)
        case NSOSStatusErrorDomain: return code == -47 /* fBsyErr */ || code == Int(Int32(bitPattern: 0xF8DA_0002)) /* kDAReturnBusy */
        default: return false
        }
    }

    private static func lane(_ path: String) -> VolumeID { VolumeID(raw: "mnt:" + path) }

    private static func path(_ url: URL) -> String {
        var p = url.standardizedFileURL.path(percentEncoded: false)
        if p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// Lane only. True when `path` (symlinks resolved) is exactly the root of its file system.
    static func isMountPoint(_ path: String) -> Bool {
        guard let real = realpath(path, nil) else { return false }
        defer { free(real) }
        var sfs = statfs()
        guard statfs(real, &sfs) == 0 else { return false }
        let mounted = withUnsafeBytes(of: &sfs.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return mounted == String(cString: real)
    }
}
