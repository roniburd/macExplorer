import Foundation
import Observation
import Core
import MacxFS

/// The batch rename sheet's state (P4-12): the rules being edited and their live preview. Every edit re-runs the
/// (pure, O(n)) planner 50 ms after the last change on a detached task; a newer edit supersedes an older one. The
/// folder's names are snapshotted once, when the sheet opens, so the preview never touches the file system.
@MainActor @Observable
final class BatchRenameModel {
    var rules = BatchRenameRules() {
        didSet { if rules != oldValue { schedule() } }
    }
    private(set) var preview: BatchRenamePreview?
    private(set) var isComputing = false
    /// Tests: how many previews finished (superseded ones don't count).
    @ObservationIgnored private(set) var generationsComputed = 0

    @ObservationIgnored let urls: [URL]
    @ObservationIgnored private let existingNames: [String]
    @ObservationIgnored private let caseSensitive: Bool
    @ObservationIgnored private let perform: @MainActor (JobRequest) async -> JobOutcome
    @ObservationIgnored private let origin: OriginID?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var applied = false

    /// Debounce between the last edit and the preview run.
    nonisolated static let debounce: Duration = .milliseconds(50)

    init(urls: [URL], existingNames: [String], caseSensitive: Bool, origin: OriginID?,
         perform: @escaping @MainActor (JobRequest) async -> JobOutcome) {
        self.urls = urls
        self.existingNames = existingNames
        self.caseSensitive = caseSensitive
        self.origin = origin
        self.perform = perform
        schedule()
    }

    /// The selected items of `folder` (display order; packages keep their extension), with every name of the
    /// folder (hidden included) as the existing names.
    convenience init(urls: [URL], folder: FolderModel, context: UIContext, origin: OriginID?) {
        let store = folder.store
        let names = (0..<store.count).map { store.name(UInt32($0)) }
        let operations = context.environment.operations
        self.init(urls: Self.planningURLs(urls), existingNames: names, caseSensitive: folder.caseSensitive, origin: origin,
                  perform: { await operations.perform($0) })
    }

    /// The planner treats a URL with a directory path as all base name. Packages (`Foo.app`) keep their extension.
    nonisolated static func planningURLs(_ urls: [URL]) -> [URL] {
        urls.map { url in
            guard url.hasDirectoryPath, !url.pathExtension.isEmpty else { return url }
            return URL(filePath: url.path(percentEncoded: false), directoryHint: .notDirectory)
        }
    }

    var title: String { String(format: L10n.string("Rename %lld Items"), Int64(urls.count)) }
    var canApply: Bool { preview?.canApply == true && !isComputing && !applied }

    private func schedule() {
        generation += 1
        let wanted = generation
        let urls = urls, rules = rules, caseSensitive = caseSensitive, names = existingNames
        isComputing = true
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) {
                BatchRenamePlanner.preview(urls, rules: rules, caseSensitive: caseSensitive, existingNames: names)
            }.value
            guard let self, wanted == self.generation else { return }
            self.preview = result
            self.isComputing = false
            self.generationsComputed += 1
        }
    }

    /// Waits for a scheduled preview, then runs the batch rename job when the preview allows it. nil: nothing ran.
    func apply() async -> JobOutcome? {
        await task?.value
        guard let preview, preview.canApply, !applied else { return nil }
        let pairs = BatchRenamePlanner.pairs(preview)
        guard !pairs.isEmpty else { return nil }
        applied = true
        return await perform(JobRequest(.batchRename(pairs), origin: origin))
    }
}
