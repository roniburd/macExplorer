import Foundation
import Core
import MacxFS

/// The search UI's strings (P3-10): notices, diagnostics, progress and summaries, chip and filter titles.
@MainActor
enum SearchStrings {
    static func diagnostic(_ d: SyntaxDiagnostic) -> String {
        String(format: L10n.string("search.diagnostic"), d.token)
    }

    static func notice(_ notice: SearchNotice) -> String {
        switch notice {
        case .contentsNotIndexed(let volume): String(format: L10n.string("search.notice.contentsNotIndexed"), volume)
        case .spotlightOff: L10n.string("search.notice.spotlightOff")
        case .truncated(let limit): String(format: L10n.string("search.notice.truncated"), count(limit))
        case .skippedLocations(let n): String(format: L10n.string("search.notice.skipped"), count(n))
        case .mayNotBeIndexed: L10n.string("search.notice.mayNotBeIndexed")
        }
    }

    static func progress(_ p: SearchProgress) -> String {
        String(format: L10n.string("search.progress"), count(p.resultCount), count(p.directoriesScanned))
    }

    static func summary(_ s: SearchSummary) -> String {
        s.resultCount == 1 ? L10n.string("search.summary.one") : String(format: L10n.string("search.summary"), count(s.resultCount))
    }

    static func stopped(_ s: SearchSummary) -> String {
        String(format: L10n.string("search.stopped"), count(s.resultCount))
    }

    /// The status line for a results state (progress, summary, stopped); nil for a failure (the empty state says it).
    static func status(_ state: SearchState) -> String? {
        switch state {
        case .searching(let p): progress(p)
        case .complete(let s): summary(s)
        case .stopped(let s): stopped(s)
        case .failed: nil
        }
    }

    static func resultsTitle(_ rootName: String) -> String { String(format: L10n.string("search.resultsTitle"), rootName) }
    static func fieldPlaceholder(_ folderName: String) -> String { String(format: L10n.string("search.placeholder"), folderName) }

    static func scope(_ scope: SearchScope) -> String {
        switch scope {
        case .thisFolder: L10n.string("search.scope.thisFolder")
        case .subfolders: L10n.string("search.scope.subfolders")
        case .thisMac: L10n.string("search.scope.thisMac")
        }
    }

    static func mode(_ mode: SearchMode) -> String {
        switch mode {
        case .name: L10n.string("search.mode.name")
        case .contents: L10n.string("search.mode.contents")
        }
    }

    static var filters: String { L10n.string("search.filters") }
    static var stop: String { L10n.string("search.stop") }
    static var save: String { L10n.string("search.save") }
    static var clearFilters: String { L10n.string("search.clearFilters") }

    static func kind(_ kind: KindFilter) -> String {
        switch kind {
        case .folder: L10n.string("search.kind.folder")
        case .document: L10n.string("search.kind.document")
        case .text: L10n.string("search.kind.text")
        case .pdf: L10n.string("search.kind.pdf")
        case .image: L10n.string("search.kind.image")
        case .movie: L10n.string("search.kind.movie")
        case .audio: L10n.string("search.kind.audio")
        case .archive: L10n.string("search.kind.archive")
        case .application: L10n.string("search.kind.application")
        case .code: L10n.string("search.kind.code")
        }
    }

    static func day(_ day: RelativeDay) -> String {
        switch day {
        case .today: L10n.string("search.date.today")
        case .yesterday: L10n.string("search.date.yesterday")
        case .thisWeek: L10n.string("search.date.thisWeek")
        case .lastWeek: L10n.string("search.date.lastWeek")
        case .thisMonth: L10n.string("search.date.thisMonth")
        case .lastMonth: L10n.string("search.date.lastMonth")
        case .thisYear: L10n.string("search.date.thisYear")
        case .lastYear: L10n.string("search.date.lastYear")
        case .last7Days: L10n.string("search.date.last7Days")
        case .last30Days: L10n.string("search.date.last30Days")
        }
    }

    /// "Small (16 KB – 1 MB)": the word and its range in the app's decimal file sizes.
    static func size(_ word: SizeWord) -> String {
        let name: String = switch word {
        case .empty: L10n.string("search.size.empty")
        case .tiny: L10n.string("search.size.tiny")
        case .small: L10n.string("search.size.small")
        case .medium: L10n.string("search.size.medium")
        case .large: L10n.string("search.size.large")
        case .huge: L10n.string("search.size.huge")
        case .gigantic: L10n.string("search.size.gigantic")
        }
        return "\(name) (\(rangeText(word.range)))"
    }

    static func rangeText(_ range: ByteRange) -> String {
        func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
        switch (range.lower, range.upper) {
        case (let lo?, let hi?) where lo == 0 && hi == 1: return bytes(0)
        case (let lo?, let hi?): return "\(bytes(lo)) – \(bytes(hi))"
        case (let lo?, nil): return "> \(bytes(lo))"
        case (nil, let hi?): return "< \(bytes(hi))"
        case (nil, nil): return ""
        }
    }

    private static let grouping: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        return f
    }()

    static func count(_ n: Int) -> String { grouping.string(from: NSNumber(value: n)) ?? String(n) }
}
