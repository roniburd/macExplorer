import Foundation
import Darwin
import Synchronization
import MacxFS

/// Downloads a dataless iCloud / File Provider item for preview (§11: "Previews never load from dataless iCloud
/// files unless the user clicks 'Download'").
public protocol UbiquitousDownloading: Sendable {
    func startDownloading(_ url: URL) async throws
    func isDataless(_ url: URL) async -> Bool
}

/// Real iCloud/File Provider download. Tests never use it on real files (Phase 3 safety rule).
public struct SystemUbiquitousDownloader: UbiquitousDownloading {
    let lanes: LanePool
    public init(lanes: LanePool) { self.lanes = lanes }
    public func startDownloading(_ url: URL) async throws {
        try await lanes.perform(on: .unknown) { _ in try FileManager.default.startDownloadingUbiquitousItem(at: url) }
    }
    /// stat (following links, like PreviewPlanner, which describes a symlink by its target): reading SF_DATALESS
    /// never materializes.
    public func isDataless(_ url: URL) async -> Bool {
        (try? await lanes.perform(on: .unknown) { _ in
            var st = stat()
            guard stat(url.path(percentEncoded: false), &st) == 0 else { return false }
            return st.st_flags & UInt32(SF_DATALESS) != 0
        }) ?? false
    }
}

/// Before `startDownloading(url)` every poll is dataless; afterwards the first `datalessPolls` polls still are.
public final class FakeUbiquitousDownloader: UbiquitousDownloading {
    private struct State { var started: [URL] = []; var polls: [URL: Int] = [:] }
    private let state = Mutex(State())
    private let datalessPolls: Int
    private let failStart: Bool
    public init(datalessPolls: Int = 2, failStart: Bool = false) { self.datalessPolls = datalessPolls; self.failStart = failStart }
    public func started() -> [URL] { state.withLock { $0.started } }
    public func startDownloading(_ url: URL) async throws {
        state.withLock { $0.started.append(url) }
        if failStart { throw CocoaError(.ubiquitousFileUnavailable) }
        state.withLock { $0.polls[url] = 0 }
    }
    public func isDataless(_ url: URL) async -> Bool {
        state.withLock { s in
            guard let n = s.polls[url] else { return true }
            s.polls[url] = n + 1
            return n < datalessPolls
        }
    }
}

public enum DownloadState: Sendable, Equatable { case downloading, done, failed, timedOut }

public enum DownloadWatcher {
    /// Yields `.downloading`, starts the download (a throw yields `.failed`), then polls `isDataless` every
    /// `pollInterval` until it clears (`.done`) or `timeout` passes (`.timedOut`). Ending iteration cancels polling.
    public static func download(_ url: URL, using downloader: any UbiquitousDownloading,
                                pollInterval: Duration = .milliseconds(500), timeout: Duration = .seconds(600)) -> AsyncStream<DownloadState> {
        AsyncStream { continuation in
            let task = Task {
                continuation.yield(.downloading)
                do { try await downloader.startDownloading(url) } catch {
                    continuation.yield(.failed)
                    continuation.finish()
                    return
                }
                let deadline = ContinuousClock.now + timeout
                while !Task.isCancelled {
                    if !(await downloader.isDataless(url)) { continuation.yield(.done); break }
                    if ContinuousClock.now >= deadline { continuation.yield(.timedOut); break }
                    try? await Task.sleep(for: pollInterval)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
