import Foundation

public struct SessionMarker: Codable, Sendable, Equatable {
    public var pid: Int32
    public var version: String
    public var build: String
    public var launchedAt: Date
    public init(pid: Int32, version: String, build: String, launchedAt: Date) {
        self.pid = pid
        self.version = version
        self.build = build
        self.launchedAt = launchedAt
    }
}

public enum PreviousSession: Sendable, Equatable {
    case clean
    case dirty(SessionMarker)
    /// A marker exists but can't be read: the last session didn't end cleanly; its launch time is unknown.
    case dirtyUnknown
}

/// Written at launch, removed on clean termination (spec §4.2). Small, synchronous, local file I/O.
public struct DirtyExitMarker: Sendable {
    public let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }

    public func previous() -> PreviousSession {
        guard let data = try? Data(contentsOf: fileURL) else { return .clean }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let marker = try? decoder.decode(SessionMarker.self, from: data) else { return .dirtyUnknown }
        return .dirty(marker)
    }

    public func begin(_ marker: SessionMarker) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(marker).write(to: fileURL, options: .atomic)
    }

    public func end() { try? FileManager.default.removeItem(at: fileURL) }
}
