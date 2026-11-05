import Foundation

/// The part of a crash report that goes into the GitHub issue (spec §4.2), with the home path replaced by `~`.
public struct CrashExcerpt: Sendable, Equatable {
    public static let maxFrames = 20

    public var exceptionType: String?
    public var signal: String?
    public var terminationReason: String?
    public var frames: [String]
    public var appVersion: String
    public var build: String

    public init(exceptionType: String?, signal: String?, terminationReason: String?, frames: [String],
                appVersion: String, build: String) {
        self.exceptionType = exceptionType
        self.signal = signal
        self.terminationReason = terminationReason
        self.frames = frames
        self.appVersion = appVersion
        self.build = build
    }

    public var title: String {
        let kind = [exceptionType, signal.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
        return "Crash: \(kind.isEmpty ? "unknown" : kind) in \(appVersion)"
    }

    public var text: String {
        var lines = ["MacExplorer \(appVersion) (\(build))"]
        if let exceptionType { lines.append("Exception: \(exceptionType)\(signal.map { " (\($0))" } ?? "")") }
        if let terminationReason { lines.append("Termination: \(terminationReason)") }
        lines.append("Crashed thread:")
        lines += frames
        return lines.joined(separator: "\n")
    }

    public static func redact(_ text: String, home: String) -> String {
        let h = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !h.isEmpty else { return text }
        // Replace "<home>" only when followed by "/" or the end, never inside a longer name (/Users/testerX).
        var out = "", rest = Substring(text)
        while let r = rest.range(of: h) {
            let after = rest[r.upperBound...]
            out += rest[..<r.lowerBound]
            if after.isEmpty || after.hasPrefix("/") { out += "~" } else { out += h }
            rest = after
        }
        return out + rest
    }

    /// Parses an `.ips` (header JSON line, newline, body JSON). Redaction is applied to the decoded values, because
    /// `.ips` files escape "/" as "\/" and a raw-text replacement would miss them.
    public static func parse(_ text: String, home: String) -> CrashExcerpt? {
        guard let newline = text.firstIndex(of: "\n"),
              let header = json(text[..<newline]),
              let body = json(text[text.index(after: newline)...]) else { return nil }
        func clean(_ value: Any?) -> String? { (value as? String).map { redact($0, home: home) } }
        let exception = body["exception"] as? [String: Any]
        let termination = body["termination"] as? [String: Any]
        let images = (body["usedImages"] as? [[String: Any]]) ?? []
        let threads = (body["threads"] as? [[String: Any]]) ?? []
        let faulting = body["faultingThread"] as? Int
        let crashed = threads.first { $0["triggered"] as? Bool == true }
            ?? faulting.flatMap { threads.indices.contains($0) ? threads[$0] : nil }
        let rawFrames = (crashed?["frames"] as? [[String: Any]]) ?? []
        let frames = rawFrames.prefix(maxFrames).enumerated().map { i, f -> String in
            let imageIndex = f["imageIndex"] as? Int
            let image = imageIndex.flatMap { images.indices.contains($0) ? clean(images[$0]["name"]) : nil } ?? "???"
            if let symbol = clean(f["symbol"]) {
                return "\(i)  \(image)  \(symbol) + \(f["symbolLocation"] as? Int ?? 0)"
            }
            return "\(i)  \(image)  + 0x\(String(f["imageOffset"] as? Int ?? 0, radix: 16))"
        }
        return CrashExcerpt(exceptionType: clean(exception?["type"]), signal: clean(exception?["signal"]),
                            terminationReason: clean(termination?["indicator"]), frames: frames,
                            appVersion: clean(header["app_version"]) ?? "unknown",
                            build: clean(header["build_version"]) ?? "unknown")
    }

    private static func json(_ s: Substring) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]
    }
}
