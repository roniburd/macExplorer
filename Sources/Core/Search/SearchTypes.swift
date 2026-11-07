import Foundation
import MacxFS

/// Matches found in one directory (crawler) or one parent (Spotlight). `batch.generation` is the search generation.
public struct SearchBatch: Sendable {
    public var parent: URL
    public var batch: Batch
    public init(parent: URL, batch: Batch) { self.parent = parent; self.batch = batch }
}

public struct SearchProgress: Sendable, Equatable {
    public var directoriesScanned: Int
    public var resultCount: Int
    public var currentPath: String?
    public init(directoriesScanned: Int = 0, resultCount: Int = 0, currentPath: String? = nil) {
        self.directoriesScanned = directoriesScanned
        self.resultCount = resultCount
        self.currentPath = currentPath
    }
}

public enum SkipReason: Sendable, Equatable { case permission(Int32), protectedLocation, unresponsive }

public struct SkippedLocation: Sendable, Equatable {
    public var path: String
    public var reason: SkipReason
    public init(path: String, reason: SkipReason) { self.path = path; self.reason = reason }
}

public struct SearchSummary: Sendable, Equatable {
    public var resultCount: Int
    public var directoriesScanned: Int
    public var skipped: [SkippedLocation]          // first 50
    public var skippedTotal: Int
    public var truncated: Bool
    public var elapsed: Duration
    public init(resultCount: Int = 0, directoriesScanned: Int = 0, skipped: [SkippedLocation] = [], skippedTotal: Int = 0,
                truncated: Bool = false, elapsed: Duration = .zero) {
        self.resultCount = resultCount
        self.directoriesScanned = directoriesScanned
        self.skipped = skipped
        self.skippedTotal = skippedTotal
        self.truncated = truncated
        self.elapsed = elapsed
    }
}

public enum SearchFailure: Error, Sendable, Equatable { case rootUnreadable(Reason), volumeUnresponsive, spotlightFailed }

public enum SearchNotice: Sendable, Equatable {
    case contentsNotIndexed(volumeName: String)    // fell back to name search
    case spotlightOff                              // This Mac unavailable
    case truncated(limit: Int)
    case skippedLocations(count: Int)
    case mayNotBeIndexed                           // folder-scoped Spotlight search finished with 0 results
}

public enum SearchEvent: Sendable {
    case batch(SearchBatch), removed([String]), progress(SearchProgress), notice(SearchNotice)
    case completed(SearchSummary), failed(SearchFailure)
}
