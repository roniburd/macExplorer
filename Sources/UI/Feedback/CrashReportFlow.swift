import AppKit
import Core

/// Next-launch crash reporting (spec §4.2): only after a dirty exit, only for a crash report we haven't offered,
/// only when the user hasn't turned it off. The search runs off the main actor.
@MainActor final class CrashReportFlow {
    private let settings: Core.Settings
    private let previous: PreviousSession
    private let locator: CrashReportLocator
    private let home: String
    private let environment: EnvironmentSummary
    private let prompt: any CrashPrompting
    private let opener: any ExternalURLOpening
    private let copyText: @MainActor (String) -> Void
    private let reveal: @MainActor (URL) -> Void

    init(settings: Core.Settings, previous: PreviousSession, locator: CrashReportLocator, home: String,
         environment: EnvironmentSummary, prompt: any CrashPrompting, opener: any ExternalURLOpening,
         copyText: @escaping @MainActor (String) -> Void, reveal: @escaping @MainActor (URL) -> Void) {
        self.settings = settings
        self.previous = previous
        self.locator = locator
        self.home = home
        self.environment = environment
        self.prompt = prompt
        self.opener = opener
        self.copyText = copyText
        self.reveal = reveal
    }

    /// At most this many reports are read in full per launch (each is at most CrashReportLocator.maxFileSize).
    nonisolated static let maxCandidates = 5

    private struct Found: Sendable {
        var report: CrashReport
        var excerpt: CrashExcerpt
        var fullRedacted: String
    }

    /// nil when nothing was asked.
    @discardableResult
    func run(on window: NSWindow?) async -> CrashAnswer? {
        guard settings.offerToReportCrashes else { return nil }
        let after: Date?
        switch previous {
        case .clean: return nil
        case .dirty(let marker): after = marker.launchedAt
        case .dirtyUnknown: after = nil
        }
        let locator = self.locator, reported = Set(settings.lastReportedCrashes), home = self.home
        let found = await Task.detached(priority: .utility) { () -> Found? in
            // Newest first; a report whose header looks right but whose body is truncated or not UTF-8 is skipped
            // so an older, readable report from the same session is still offered.
            for report in locator.candidates(after: after, excluding: reported).prefix(Self.maxCandidates) {
                guard let data = try? Data(contentsOf: report.fileURL),
                      let text = String(data: data, encoding: .utf8),
                      let excerpt = CrashExcerpt.parse(text, home: home) else { continue }
                return Found(report: report, excerpt: excerpt, fullRedacted: CrashExcerpt.redact(text, home: home))
            }
            return nil
        }.value
        guard let found else {
            NSLog("MacExplorer: previous session ended without a clean quit; no crash report found")
            return nil
        }
        // Recorded before asking, so quitting (or crashing) with the sheet up never offers this report again.
        settings.markCrashReported(found.report.fileName)
        let answer = await prompt.ask(title: found.excerpt.title, on: window)
        if answer.dontAskAgain { settings.offerToReportCrashes = false }
        switch answer.choice {
        case .report:
            copyText(found.fullRedacted)
            opener.open(IssueURLBuilder.url(kind: .bug, environment: environment, title: found.excerpt.title,
                                            crashExcerpt: found.excerpt.text))
        case .showReport:
            reveal(found.report.fileURL)
        case .dontSend:
            break
        }
        return answer
    }
}

/// Live wiring (AppBootstrap): the previous session's marker was read before this launch's marker was written.
@MainActor public enum CrashReporting {
    public static func start(context: UIContext, previous: PreviousSession, statePaths: StatePaths) {
        let options = context.options
        let pasteboard = options.pasteboardName.map { NSPasteboard(name: NSPasteboard.Name($0)) } ?? .general
        let flow = CrashReportFlow(
            settings: context.environment.settings, previous: previous,
            locator: CrashReportLocator(directory: statePaths.diagnosticReports(sandboxed: options.isSandboxed),
                                        bundleID: Bundle.main.bundleIdentifier ?? "com.macexplorer.app"),
            home: FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false),
            environment: EnvironmentSummary.current(channel: context.environment.settings.updateChannel),
            prompt: AlertCrashPrompt(), opener: ExternalOpeners.opener(for: options),
            copyText: { text in
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            },
            reveal: { url in
                if options.isSandboxed { RecordingURLOpener.shared.open(url) } else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            })
        Task { @MainActor in await flow.run(on: context.windows.windows.first?.window) }
    }
}
