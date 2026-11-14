import Foundation

/// What a `--smoke-exit-after` run writes to `<state-dir>/smoke.json` before exiting 0.
public struct SmokeReport: Codable, Sendable, Equatable {
    public static let fileName = "smoke.json"

    /// Titles of the visible windows at exit time, front to back.
    public var windowTitles: [String]
    /// The `--root` path the first window opened, if any.
    public var root: String?
    public var processID: Int32
    /// Provider ids of the plugins loaded this launch (nil when loading was skipped or hadn't finished).
    public var plugins: [String]? = nil
    /// "<bundle>.macxplugin: <reason>" for each plugin bundle refused this launch.
    public var pluginFailures: [String]? = nil

    public init(windowTitles: [String], root: String?, processID: Int32, plugins: [String]? = nil,
                pluginFailures: [String]? = nil) {
        self.windowTitles = windowTitles
        self.root = root
        self.processID = processID
        self.plugins = plugins
        self.pluginFailures = pluginFailures
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> SmokeReport {
        try JSONDecoder().decode(SmokeReport.self, from: Data(contentsOf: url))
    }
}
