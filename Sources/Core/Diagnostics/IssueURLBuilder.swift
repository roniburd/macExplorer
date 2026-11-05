import Foundation

public enum IssueKind: String, Sendable, CaseIterable {
    case bug, feature
    public var template: String { "\(rawValue).yml" }
}

/// Field `id:`s in `.github/ISSUE_TEMPLATE/*.yml` (IssueURLBuilderTests checks they exist there).
public enum IssueField {
    public static let whatHappened = "what-happened", steps = "steps", expected = "expected"
    public static let version = "version", macos = "macos", hardware = "hardware", channel = "channel"
    public static let crashLog = "crash-log", problem = "problem", proposal = "proposal"

    public static func ids(for kind: IssueKind) -> [String] {
        switch kind {
        case .bug: [whatHappened, steps, expected, version, macos, hardware, channel, crashLog]
        case .feature: [problem, proposal, version]
        }
    }
}

/// Prefilled GitHub issue-form links (spec §4.1). No network, no token: the user reviews and submits on GitHub.
public enum IssueURLBuilder {
    public static let newIssueBase = URL(string: "https://github.com/roniburd/macExplorer/issues/new")!
    /// GitHub's practical URL limit is ~8 KB; stay well under it.
    public static let maxLength = 7500
    public static let truncationMarker = "\n… [truncated — full report on clipboard]"
    /// Encoded-length caps for the head fields, so title + environment can never crowd out the cap
    /// (the title embeds fields parsed from an on-disk .ips, which may be garbage — Review Focus 3).
    static let titleBudget = 600, fieldBudget = 300
    static let fieldMarker = "…"

    /// Unreserved characters only (RFC 3986): `+`, `&`, `=`, `#` and everything else are percent-encoded.
    private static let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }

    public static func url(kind: IssueKind, environment: EnvironmentSummary, title: String? = nil,
                           crashExcerpt: String? = nil) -> URL {
        var pairs: [(String, String, Int)] = [("template", kind.template, fieldBudget)]
        if let title { pairs.append(("title", title, titleBudget)) }
        switch kind {
        case .bug:
            pairs += [(IssueField.version, environment.versionLine, fieldBudget),
                      (IssueField.macos, environment.macOS, fieldBudget),
                      (IssueField.hardware, environment.hardwareLine, fieldBudget),
                      (IssueField.channel, environment.channel, fieldBudget)]
        case .feature:
            pairs.append((IssueField.version, environment.versionLine, fieldBudget))
        }
        let head = newIssueBase.absoluteString + "?" + pairs.map {
            "\(encode($0.0))=\(fitted($0.1, budget: $0.2, marker: fieldMarker))"
        }.joined(separator: "&")
        guard kind == .bug, let crashExcerpt, !crashExcerpt.isEmpty else { return URL(string: head)! }
        let prefix = "&\(IssueField.crashLog)="
        let budget = maxLength - head.count - prefix.count
        // Defensive: with the head caps above this cannot happen, but never exceed maxLength.
        guard budget >= encode(truncationMarker).count else { return URL(string: head)! }
        return URL(string: head + prefix + fitted(crashExcerpt, budget: budget))!
    }

    /// The whole text if its encoding fits `budget`, else the longest prefix (whole Characters) + `marker` that does.
    /// Callers must pass `budget >= encode(marker).count`; the bare marker is the floor.
    static func fitted(_ text: String, budget: Int, marker: String = truncationMarker) -> String {
        let full = encode(text)
        if full.count <= budget { return full }
        let chars = Array(text)
        var lo = 0, hi = chars.count, best = encode(marker)
        while lo <= hi {
            let mid = (lo + hi) / 2
            let candidate = encode(String(chars[0..<mid]) + marker)
            if candidate.count <= budget { best = candidate; lo = mid + 1 } else { hi = mid - 1 }
        }
        return best
    }
}
