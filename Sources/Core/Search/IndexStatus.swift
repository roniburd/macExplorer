import Foundation
import Synchronization
import MacxFS

public enum IndexingStatus: String, Sendable, Codable { case enabled, disabled, unknown }

public protocol IndexStatusProviding: Sendable {
    func status(ofVolumeAt mountPoint: URL) async -> IndexingStatus
}

public struct FixedIndexStatus: IndexStatusProviding {
    let value: IndexingStatus
    public init(_ status: IndexingStatus) { value = status }
    public func status(ofVolumeAt mountPoint: URL) async -> IndexingStatus { value }
}

/// `/usr/bin/mdutil -s` (status only; never -i/-E/-X) on a lane, with timeout and a per-mount-point cache.
public final class MdutilIndexStatus: IndexStatusProviding {
    private let lanes: LanePool
    private let timeout: Duration
    private let cacheLifetime: Duration
    private let cache = Mutex<[String: CacheEntry]>([:])
    private struct CacheEntry: Sendable { var status: IndexingStatus; var at: ContinuousClock.Instant }

    public init(lanes: LanePool, timeout: Duration = .seconds(2), cacheLifetime: Duration = .seconds(60)) {
        self.lanes = lanes; self.timeout = timeout; self.cacheLifetime = cacheLifetime
    }

    public func status(ofVolumeAt mountPoint: URL) async -> IndexingStatus {
        let key = CrawlPermissions.trim(mountPoint.standardizedFileURL.path(percentEncoded: false))
        let lifetime = cacheLifetime
        if let hit = cache.withLock({ $0[key] }), ContinuousClock.now - hit.at < lifetime { return hit.status }
        let timeout = self.timeout
        let status = (try? await lanes.perform(on: .unknown) { context in
            Self.runMdutil(key, timeout: timeout, context: context)
        }) ?? .unknown
        cache.withLock { $0[key] = CacheEntry(status: status, at: ContinuousClock.now) }
        return status
    }

    static func runMdutil(_ path: String, timeout: Duration, context: LaneContext) -> IndexingStatus {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/mdutil")
        process.arguments = ["-s", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return .unknown }
        let deadline = ContinuousClock.now + timeout
        while process.isRunning {
            if ContinuousClock.now >= deadline { process.terminate(); return .unknown }
            context.heartbeat()
            usleep(20_000)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return parse(String(decoding: data, as: UTF8.self))
    }

    public static func parse(_ output: String) -> IndexingStatus {
        let text = output.lowercased()
        if text.contains("indexing enabled") { return .enabled }
        if text.contains("index is read-only") { return .enabled }    // macOS 26: sealed / Data volume, still searchable
        if text.contains("disabled") { return .disabled }
        return .unknown
    }
}
