import Foundation

public struct CrashReport: Sendable, Equatable {
    public var fileURL: URL
    public var fileName: String
    public var timestamp: Date

    public init(fileURL: URL, fileName: String, timestamp: Date) {
        self.fileURL = fileURL
        self.fileName = fileName
        self.timestamp = timestamp
    }
}

/// Finds macOS's crash report for our previous session (spec §4.2). Blocking file I/O: call off the main actor.
public struct CrashReportLocator: Sendable {
    public static let maxFileSize = 8 * 1024 * 1024
    /// Only the header line is read to classify a report; real headers are well under 1 KB.
    static let maxHeaderBytes = 64 * 1024
    /// `bug_type` of a crash report (hangs and spins use other values).
    static let crashBugType = "309"

    public let directory: URL
    public let bundleID: String
    public let processName: String

    public init(directory: URL, bundleID: String, processName: String = "macExplorer") {
        self.directory = directory
        self.bundleID = bundleID
        self.processName = processName
    }

    public func newest(after launchedAt: Date?, excluding reported: Set<String>) -> CrashReport? {
        candidates(after: launchedAt, excluding: reported).first
    }

    /// Every matching report, newest first. Only headers are checked here, so a caller that needs the body should
    /// fall back to the next candidate when one turns out truncated or garbage (review of the branch).
    public func candidates(after launchedAt: Date?, excluding reported: Set<String>) -> [CrashReport] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else {
            return []
        }
        return urls
            .filter { !reported.contains($0.lastPathComponent) }
            .compactMap { report(at: $0, keys: Set(keys)) }
            .filter { report in launchedAt.map { report.timestamp > $0 } ?? true }
            .sorted { $0.timestamp > $1.timestamp }
    }

    private func report(at url: URL, keys: Set<URLResourceKey>) -> CrashReport? {
        let name = url.lastPathComponent
        guard name.hasPrefix("\(processName)-"), url.pathExtension == "ips",
              let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
              let size = values.fileSize, size <= Self.maxFileSize,
              let data = Self.readPrefix(url, max: Self.maxHeaderBytes),
              let header = Self.header(data),
              header["bundleID"] as? String == bundleID,
              header["bug_type"] as? String == Self.crashBugType else { return nil }
        let stamp = (header["timestamp"] as? String).flatMap(Self.parseTimestamp)
            ?? values.contentModificationDate ?? .distantPast
        return CrashReport(fileURL: url, fileName: name, timestamp: stamp)
    }

    private static func readPrefix(_ url: URL, max: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: max)
    }

    /// Line 1 of an `.ips` is a JSON object.
    static func header(_ data: Data) -> [String: Any]? {
        let line = data.prefix { $0 != UInt8(ascii: "\n") }
        return (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }

    /// "2026-11-04 10:11:12.00 -0800"
    static func parseTimestamp(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SS Z"
        return f.date(from: s)
    }
}
