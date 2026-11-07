import AppKit
import Core
import MacxFS

/// The window's preview pane (§11 Phase 3, inspector split item): Quick Look or a fast text preview of the single
/// selected item, a message for folders, multiple items, iCloud placeholders, broken links and unreadable items, and a
/// details summary. Selection changes are debounced and stamped with a generation, so a stale result never shows.
/// While collapsed (`isActive == false`) it does no work at all.
@MainActor
final class PreviewPaneController: NSViewController {
    typealias Resolver = @MainActor (PreviewSubject) async -> PreviewContent

    enum DisplayState: Equatable {
        case hidden, nothing, loading
        case multiple(Int, Int64)
        case text(String, truncated: Bool)
        case quickLook(URL), folder(URL), cloud(URL), downloading(URL), downloadFailed(URL), broken(URL)
        case unavailable(URL, Int32)
    }

    /// PreviewPlanner on the read lanes: the main thread never stats, opens or sniffs the item (§4.4).
    static func defaultResolve(_ env: CoreEnvironment) -> Resolver {
        { subject in
            let volume = env.volumes.volume(for: subject.url)?.id ?? .unknown
            return await PreviewPlanner.resolve(subject, lanes: env.lanes, volume: volume, types: env.types)
        }
    }

    /// What was last resolved; an event that leaves it unchanged (a selection re-sent, an unrelated row change) does
    /// not reload the preview or interrupt a download.
    private enum SelectionKey: Equatable {
        case empty
        case multiple(Int, Int64)
        case single(URL, kind: Kind, size: Int64, mtime: Int64, flags: UInt32)
    }

    private let context: UIContext
    private let makeHost: @MainActor () -> any QuickLookHosting
    private let debounce: Duration
    private let resolve: Resolver
    private lazy var host = makeHost()
    private let textView = TextPreviewView()
    private let messageView = PreviewMessageView()
    private let detailsView = PreviewDetailsView()
    private let stack = NSStackView()
    private weak var source: (any RowSource)?
    private var sourceToken: ObserverToken?
    private var pending: Task<Void, Never>?
    private var detailsTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var generation = 0
    private var lastKey: SelectionKey?
    /// The Finder display name of the single subject (the folder message shows it).
    private var subjectName = ""

    private(set) var displayState: DisplayState = .hidden
    private(set) var details: PreviewDetails?
    /// Text loads started (tests: a dataless item is never read).
    private(set) var textLoads = 0
    /// nil: the environment's (`searchServices.downloader`; sandboxed environments use the fake).
    var downloader: (any UbiquitousDownloading)?
    var downloadPollInterval: Duration = .milliseconds(500)
    var truncationFooterHidden: Bool { textView.footerHidden }
    var messageTitle: String { messageView.title }
    var messageButtonTitle: String? { messageView.buttonTitle }
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            if isActive { observeSource(); scheduleUpdate(immediate: true, force: true) } else { deactivate() }
        }
    }

    init(context: UIContext, makeHost: @escaping @MainActor () -> any QuickLookHosting = { QLPreviewViewHost() },
         debounce: Duration = .milliseconds(120), resolve: Resolver? = nil) {
        self.context = context
        self.makeHost = makeHost
        self.debounce = debounce
        self.resolve = resolve ?? Self.defaultResolve(context.environment)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("PreviewPaneController is created in code") }

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        let hostView = host.view
        hostView.translatesAutoresizingMaskIntoConstraints = false
        for v in [hostView, textView, messageView, detailsView] {
            stack.addArrangedSubview(v)
            v.isHidden = true
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
        }
        for v in [hostView, textView] {
            v.setContentHuggingPriority(.defaultLow, for: .vertical)
            v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
            v.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        }
        detailsView.setContentHuggingPriority(.required, for: .vertical)
        stack.setHuggingPriority(.defaultLow, for: .vertical)
        stack.setAccessibilityElement(true)
        stack.setAccessibilityRole(.group)
        stack.setAccessibilityIdentifier(AXID.previewPane)
        stack.setAccessibilityLabel(L10n.string("preview.pane"))
        messageView.onButton = { [weak self] in self?.performDownload() }
        view = stack
        render(displayState)
    }

    /// The rows the window shows (its folder or its search results); nil when the window closes.
    func bind(_ source: (any RowSource)?) {
        if source === self.source, sourceToken != nil || !isActive { return }
        self.source = source
        sourceToken?.cancel()
        sourceToken = nil
        if isActive { observeSource(); scheduleUpdate(immediate: true, force: true) }
    }

    /// The window is closing: stop everything and release Quick Look.
    func close() {
        bind(nil)
        isActive = false
        deactivate()
        if isViewLoaded { host.close() }
    }

    private func observeSource() {
        sourceToken?.cancel()
        sourceToken = source?.observeRows { [weak self] event in
            switch event {
            case .selection, .changes: self?.scheduleUpdate(immediate: false, force: false)
            case .beginRename: break
            }
        }
    }

    private func deactivate() {
        pending?.cancel(); pending = nil
        detailsTask?.cancel(); detailsTask = nil
        downloadTask?.cancel(); downloadTask = nil
        sourceToken?.cancel()
        sourceToken = nil
        generation += 1
        lastKey = nil
        if isViewLoaded { host.show(nil) }
        details = nil
        render(.hidden)
    }

    private func scheduleUpdate(immediate: Bool, force: Bool) {
        guard isActive else { return }
        pending?.cancel()
        let wait = immediate ? Duration.zero : debounce
        pending = Task { [weak self] in
            if wait > .zero { try? await Task.sleep(for: wait) }
            guard !Task.isCancelled else { return }
            await self?.update(force: force)
        }
    }

    private func selectionKey(_ source: any RowSource, rows: [Int]) -> SelectionKey {
        if rows.isEmpty { return .empty }
        if rows.count > 1 { return .multiple(rows.count, source.selectionSummary.bytes) }
        let e = source.entry(atRow: rows[0])
        return .single(source.url(atRow: rows[0]), kind: e.kind, size: e.size, mtime: e.mtime, flags: e.flags.rawValue)
    }

    private func update(force: Bool) async {
        guard isActive else { return }
        guard let source else {
            lastKey = .empty
            showNothing()
            return
        }
        let rows = source.selection.rows.filter { $0 < source.rowCount }
        let key = selectionKey(source, rows: Array(rows))
        if !force, key == lastKey { return }
        lastKey = key
        generation += 1
        let gen = generation
        downloadTask?.cancel(); downloadTask = nil
        detailsTask?.cancel(); detailsTask = nil
        details = nil                                       // the previous item's summary never shows under the next
        if isViewLoaded { detailsView.isHidden = true }
        switch key {
        case .empty:
            showNothing()
            return
        case .multiple(let n, let bytes):
            host.show(nil); details = nil
            render(.multiple(n, bytes))
            return
        case .single:
            break
        }
        let row = rows.first!
        let e = source.entry(atRow: row)
        subjectName = source.displayName(atRow: row)
        let subject = PreviewSubject(url: source.url(atRow: row), kind: e.kind, typeIndex: e.typeIndex, flags: e.flags, size: e.size)
        let content = await resolve(subject)
        guard gen == generation, isActive else { return }
        await show(content, gen: gen)
        guard gen == generation, isActive else { return }
        loadDetails(subject, content: content, gen: gen)
    }

    private func showNothing() {
        if isViewLoaded { host.show(nil) }
        details = nil
        render(.nothing)
    }

    private func show(_ content: PreviewContent, gen: Int) async {
        let env = context.environment
        switch content {
        case .nothingSelected: host.show(nil); render(.nothing)
        case .multiple(let n, let bytes): host.show(nil); render(.multiple(n, bytes))
        case .folder(let url): host.show(nil); render(.folder(url))
        case .quickLook(let url): host.show(url); render(.quickLook(url))
        case .cloudPlaceholder(let url): host.show(nil); render(.cloud(url))
        case .brokenLink(let url): host.show(nil); render(.broken(url))
        case .unavailable(let url, let code): host.show(nil); render(.unavailable(url, code))
        case .text(let url):
            textLoads += 1
            render(.loading)
            let volume = env.volumes.volume(for: url)?.id ?? .unknown
            do throws(TextPreviewError) {
                let preview = try await TextPreviewLoader.load(url, lanes: env.lanes, volume: volume)
                guard gen == generation else { return }
                host.show(nil)
                render(.text(preview.text, truncated: preview.truncated))
            } catch {
                guard gen == generation else { return }
                switch error {
                case .binary: host.show(url); render(.quickLook(url))     // text by type but not by content: Quick Look
                case .posix(let code): host.show(nil); render(.unavailable(url, code))
                }
            }
        }
    }

    private func loadDetails(_ subject: PreviewSubject, content: PreviewContent, gen: Int) {
        switch content {
        case .nothingSelected, .multiple, .brokenLink, .unavailable:
            details = nil
            detailsView.isHidden = true
            return
        case .folder, .text, .quickLook, .cloudPlaceholder:
            break
        }
        let env = context.environment
        detailsTask = Task { [weak self] in
            let volume = env.volumes.volume(for: subject.url)?.id ?? .unknown
            let d = await PreviewMetadata.load(subject.url, typeIndex: subject.typeIndex, types: env.types, lanes: env.lanes, volume: volume)
            guard let self, !Task.isCancelled, gen == self.generation, self.isActive else { return }
            self.details = d
            self.detailsView.show(d)
            self.detailsView.isHidden = false
        }
    }

    /// The "Download" / "Try Again" button and the Download for Preview command: the only way a dataless item is
    /// ever fetched (§11). When the download finishes, the item is resolved again and previewed.
    func performDownload() {
        let url: URL
        switch displayState {
        case .cloud(let u), .downloadFailed(let u): url = u
        default: return
        }
        let downloader = self.downloader ?? context.environment.searchServices.downloader
        let interval = downloadPollInterval
        let gen = generation
        downloadTask?.cancel()
        downloadTask = Task { [weak self] in
            for await state in DownloadWatcher.download(url, using: downloader, pollInterval: interval) {
                guard let self, !Task.isCancelled, gen == self.generation, self.isActive else { return }
                switch state {
                case .downloading: self.render(.downloading(url))
                case .done: self.scheduleUpdate(immediate: true, force: true)
                case .failed, .timedOut: self.render(.downloadFailed(url))
                }
            }
        }
    }

    private func render(_ state: DisplayState) {
        displayState = state
        guard isViewLoaded else { return }
        host.view.isHidden = { if case .quickLook = state { false } else { true } }()
        textView.isHidden = true
        messageView.isHidden = true
        switch state {
        case .hidden, .loading, .quickLook:
            break
        case .text(let text, let truncated):
            textView.show(text, truncated: truncated)
            textView.isHidden = false
        case .nothing:
            message(symbol: "eye.slash", title: L10n.string("preview.nothing"))
        case .multiple(let n, let bytes):
            let count = NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)
            message(symbol: "square.stack", title: String(format: L10n.string("preview.multiple"), count, Formatters.bytes(bytes)))
        case .folder:
            message(symbol: "folder", title: subjectName)
        case .cloud:
            message(symbol: "icloud.and.arrow.down", title: L10n.string("preview.cloud"), button: L10n.string("preview.download"))
        case .downloading:
            message(symbol: "icloud.and.arrow.down", title: L10n.string("preview.downloading"), spinner: true)
        case .downloadFailed:
            message(symbol: "exclamationmark.icloud", title: L10n.string("preview.downloadFailed"), button: L10n.string("preview.tryAgain"))
        case .broken:
            message(symbol: "questionmark.folder", title: L10n.string("preview.broken"))
        case .unavailable(_, let code):
            message(symbol: "eye.trianglebadge.exclamationmark", title: L10n.string("preview.unavailable"),
                    detail: POSIXErrorCode(rawValue: code).map { String(cString: strerror($0.rawValue)) })
        }
        switch state {
        case .hidden, .nothing, .multiple: detailsView.isHidden = true
        default: detailsView.isHidden = details == nil
        }
    }

    private func message(symbol: String, title: String, detail: String? = nil, button: String? = nil, spinner: Bool = false) {
        messageView.show(symbol: symbol, title: title, detail: detail, button: button, spinner: spinner)
        messageView.isHidden = false
    }

    /// Scenario probe text: "hidden", "nothing", "loading", "multiple:2", "text", "quickLook", "folder", "cloud",
    /// "downloading", "downloadFailed", "broken", "unavailable".
    var probeState: String {
        switch displayState {
        case .hidden: "hidden"
        case .nothing: "nothing"
        case .loading: "loading"
        case .multiple(let n, _): "multiple:\(n)"
        case .text: "text"
        case .quickLook: "quickLook"
        case .folder: "folder"
        case .cloud: "cloud"
        case .downloading: "downloading"
        case .downloadFailed: "downloadFailed"
        case .broken: "broken"
        case .unavailable: "unavailable"
        }
    }

    var probeText: String? { if case .text(let t, _) = displayState { String(t.prefix(200)) } else { nil } }
}
