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
        /// A Markdown file's text: rendered or as source, per `Settings.previewRendersMarkdown`.
        case markdown(String, truncated: Bool, url: URL)
        /// A Word or OpenDocument file: its text reflowed to the pane (`reflowed`) or Quick Look's page view.
        case document(URL, reflowed: Bool)
        case quickLook(URL), folder(URL), cloud(URL), downloading(URL), downloadFailed(URL), broken(URL)
        /// A text file with no content: a message, not a blank text area (QA polish).
        case empty(URL)
        case unavailable(URL, Int32)
        /// Text by type but not by content (NUL or control bytes): a message, never Quick Look (QA round 1).
        case binary(URL)
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
        case single(URL, kind: Kind, size: Int64, mtime: Int64, flags: UInt32, fileID: UInt64)
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
    private let closeButton = NSButton()
    /// The pane's close button: the split view hides the pane, as View › Hide Preview Pane (⌥P) does.
    var onClose: (() -> Void)?
    private weak var source: (any RowSource)?
    private var sourceToken: ObserverToken?
    private var busToken: ObserverToken?
    /// A forced update is waiting: a later unforced event (debounced over it) must not drop the force.
    private var pendingForce = false
    private var pending: Task<Void, Never>?
    private var detailsTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    /// Loads the rendered Markdown's local images (cancelled when the pane shows anything else).
    private var imageTask: Task<Void, Never>?
    private var markdownImages: [MarkdownImage] = []
    /// The reflowed text of the `.document` being shown.
    private var documentText: NSAttributedString?
    /// Rendered | Source (Markdown) or Reflowed | Original (documents), above the preview.
    private let modeControl = NSSegmentedControl(labels: ["", ""], trackingMode: .selectOne, target: nil, action: nil)
    /// The zoom when it isn't 100% (click: back to 100%).
    private let zoomButton = NSButton(title: "", target: nil, action: nil)
    /// Opens the Quick Look window (resizable, full screen, zoom) over what the pane shows.
    private let expandButton = NSButton(image: NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right",
                                                       accessibilityDescription: nil) ?? NSImage(), target: nil, action: nil)
    private let topBar = NSStackView()
    /// The pane shows Quick Look content (true) or text (false); the split view widens its cap for Quick Look.
    var onQuickLookContentChange: ((Bool) -> Void)?
    private var showsQuickLookContent = false
    /// Opens the Quick Look window (the window controller's QuickLookController).
    var onOpenQuickLook: (() -> Void)?
    /// Zoom steps for ⌘= / ⌘−.
    static let zoomSteps: [Double] = [0.5, 0.67, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]
    /// Shows a file a relative Markdown link points to (the window selects it in its folder).
    var onRevealFile: ((URL) -> Void)?
    /// Opens a web or mail link (tests replace it; the default is NSWorkspace).
    var openExternal: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Fetches a remote image after the user clicks its placeholder (tests replace it).
    var fetchRemoteImage: @Sendable (URL) async -> Data? = { url in await PreviewPaneController.download(url) }
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
        // The list's background, up under the toolbar like the content pane's, so the toolbar strip doesn't change
        // colour where the pane starts.
        let container = ListBackgroundSpacer()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        // The inspector runs under the window toolbar: lay out in the visible area (QA polish: messages sat under
        // the toolbar with their symbol half hidden behind the view-mode buttons).
        let safe = container.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: safe.topAnchor),
            stack.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        let hostView = host.view
        hostView.translatesAutoresizingMaskIntoConstraints = false
        modeControl.controlSize = .small
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.setAccessibilityIdentifier(AXID.previewMode)
        modeControl.isHidden = true
        zoomButton.bezelStyle = .inline
        zoomButton.controlSize = .small
        zoomButton.target = self
        zoomButton.action = #selector(macx_previewActualSize(_:))
        zoomButton.toolTip = L10n.string("Actual Size")
        zoomButton.setAccessibilityIdentifier(AXID.previewZoom)
        zoomButton.isHidden = true
        expandButton.bezelStyle = .inline
        expandButton.isBordered = false
        expandButton.controlSize = .small
        expandButton.target = self
        expandButton.action = #selector(openQuickLookWindow)
        expandButton.toolTip = L10n.string("Open in Quick Look")
        expandButton.setAccessibilityLabel(L10n.string("Open in Quick Look"))
        expandButton.setAccessibilityIdentifier(AXID.previewExpand)
        expandButton.isHidden = true
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        topBar.orientation = .horizontal
        topBar.spacing = 6
        configureCloseButton()
        topBar.setViews([modeControl, spacer, zoomButton, expandButton, closeButton], in: .leading)
        topBar.isHidden = true
        stack.addArrangedSubview(topBar)
        topBar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
        for v in [hostView, textView, messageView, detailsView] {
            stack.addArrangedSubview(v)
            v.isHidden = true
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
        }
        for v in [hostView, textView, messageView] {
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
        textView.onLink = { [weak self] url in self?.followLink(url) ?? false }
        textView.onPinchZoom = { [weak self] zoom in self?.setZoom(Double(zoom)) }
        textView.setZoom(CGFloat(context.environment.settings.previewZoom))
        view = container
        render(displayState)
    }

    private func configureCloseButton() {
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.widthAnchor.constraint(equalToConstant: 16).isActive = true
        closeButton.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let title = L10n.string("Hide Preview Pane")
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        closeButton.imagePosition = .imageOnly
        closeButton.isBordered = false
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.showsBorderOnlyWhileMouseInside = true
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = title
        closeButton.setAccessibilityLabel(title)
        closeButton.setAccessibilityIdentifier(AXID.previewClose)
        closeButton.target = self
        closeButton.action = #selector(closeClicked(_:))
    }

    @objc private func closeClicked(_ sender: Any?) { onClose?() }

    /// Tests: clicks the close button.
    func performCloseClick() { closeButton.performClick(nil) }

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
        busToken?.cancel()
        // An in-app change to the previewed item reloads it even when its size and date look the same (QA polish).
        busToken = context.environment.changeBus.observeAll { [weak self] change in self?.localChange(change) }
        sourceToken?.cancel()
        sourceToken = source?.observeRows { [weak self] event in
            switch event {
            case .selection, .changes: self?.scheduleUpdate(immediate: false, force: false)
            case .beginRename: break
            }
        }
    }

    private func localChange(_ change: LocalChange) {
        guard case .single(let url, _, _, _, _, _)? = lastKey,
              ChangeBus.key(for: change.directory) == ChangeBus.key(for: url.deletingLastPathComponent()) else { return }
        let name = url.lastPathComponent
        if change.modified.contains(name) || change.added.contains(name) || change.renamed.contains(where: { $0.to == name }) {
            scheduleUpdate(immediate: false, force: true)
        }
    }

    private func deactivate() {
        pending?.cancel(); pending = nil
        pendingForce = false
        busToken?.cancel(); busToken = nil
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
        pendingForce = pendingForce || force
        pending = Task { [weak self] in
            if wait > .zero { try? await Task.sleep(for: wait) }
            guard !Task.isCancelled, let self else { return }
            let force = self.pendingForce
            self.pendingForce = false
            await self.update(force: force)
        }
    }

    /// Tests: waits for the latest scheduled update (debounce, resolve, show) and the details load it started, so a
    /// test can assert what did not happen without a sleep.
    func settled() async {
        while let task = pending {
            await task.value
            if task == pending { break }
        }
        while let task = detailsTask {
            await task.value
            if task == detailsTask { return }
        }
    }

    private func selectionKey(_ source: any RowSource, rows: [Int]) -> SelectionKey {
        if rows.isEmpty { return .empty }
        if rows.count > 1 { return .multiple(rows.count, source.selectionSummary.bytes) }
        let e = source.entry(atRow: rows[0])
        return .single(source.url(atRow: rows[0]), kind: e.kind, size: e.size, mtime: e.mtime, flags: e.flags.rawValue, fileID: e.fileID)
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
        case .quickLook(let url):
            // Same item, new content (its size, date or inode changed, or an in-app change named it): QLPreviewView
            // keeps showing what it loaded unless asked to reload (QA polish).
            if host.shownURL == url { host.refresh() } else { host.show(url) }
            render(.quickLook(url))
        case .document(let url):
            await showDocument(url, gen: gen)
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
                if preview.text.isEmpty && !preview.truncated {
                    render(.empty(url))
                } else if MarkdownFiles.isMarkdown(url) {
                    render(.markdown(preview.text, truncated: preview.truncated, url: url))
                } else {
                    render(.text(preview.text, truncated: preview.truncated))
                }
            } catch {
                guard gen == generation else { return }
                switch error {
                // Text by type but not by content: never Quick Look, whose Text generator would lay out the whole
                // file on the main thread (QA round 1: a 2 GB sparse .txt hung the app and grew it to 1.75 GB).
                case .binary: host.show(nil); render(.binary(url))
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
        case .folder, .text, .quickLook, .document, .cloudPlaceholder:
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
        host.view.isHidden = {
            switch state {
            case .quickLook, .document(_, reflowed: false): false
            default: true
            }
        }()
        textView.isHidden = true
        messageView.isHidden = true
        imageTask?.cancel(); imageTask = nil
        markdownImages = []
        switch state {
        case .markdown:
            showModeControl(L10n.string("Rendered"), L10n.string("Source"), first: context.environment.settings.previewRendersMarkdown)
        case .document:
            showModeControl(L10n.string("Reflowed"), L10n.string("Original"), first: context.environment.settings.previewReflowsDocuments)
        default:
            modeControl.isHidden = true
        }
        if case .document = state {} else { documentText = nil }
        let quickLookContent: Bool = switch state {
        case .quickLook, .document(_, reflowed: false): true
        default: false
        }
        expandButton.isHidden = !quickLookContent || onOpenQuickLook == nil
        updateZoomButton(for: state)
        topBar.isHidden = state == .hidden            // the close button always shows while the pane does
        if quickLookContent != showsQuickLookContent {
            showsQuickLookContent = quickLookContent
            onQuickLookContentChange?(quickLookContent)
        }
        switch state {
        case .hidden, .loading, .quickLook:
            break
        case .text(let text, let truncated):
            textView.show(text, truncated: truncated)
            textView.isHidden = false
        case .markdown(let text, let truncated, let url):
            if context.environment.settings.previewRendersMarkdown {
                let rendering = MarkdownRenderer.render(text, fileURL: url)
                textView.showRendered(rendering.text, truncated: truncated)
                markdownImages = rendering.images
                loadLocalImages(rendering.images)
            } else {
                textView.show(text, truncated: truncated)
            }
            textView.isHidden = false
        case .document(_, let reflowed):
            if reflowed, let text = documentText {
                textView.showRendered(text, truncated: false)
                textView.isHidden = false
            }
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
        case .empty:
            message(symbol: "doc", title: L10n.string("preview.empty"))
        case .binary:
            message(symbol: "doc", title: L10n.string("preview.binary"), detail: L10n.string("preview.binary.detail"))
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
    /// "downloading", "downloadFailed", "broken", "unavailable", "binary", "empty", "markdown", "markdownSource".
    var probeState: String {
        switch displayState {
        case .hidden: "hidden"
        case .nothing: "nothing"
        case .loading: "loading"
        case .multiple(let n, _): "multiple:\(n)"
        case .text: "text"
        case .markdown: context.environment.settings.previewRendersMarkdown ? "markdown" : "markdownSource"
        case .document(_, let reflowed): reflowed ? "document" : "documentOriginal"
        case .quickLook: "quickLook"
        case .folder: "folder"
        case .cloud: "cloud"
        case .downloading: "downloading"
        case .downloadFailed: "downloadFailed"
        case .broken: "broken"
        case .unavailable: "unavailable"
        case .binary: "binary"
        case .empty: "empty"
        }
    }

    /// The message's icon, title and detail, in the pane view's coordinates (tests: centred in the safe area).
    var messageContentFrame: NSRect {
        guard isViewLoaded, !messageView.isHidden else { return .zero }
        return messageView.convert(messageView.contentFrame, to: view)
    }

    var probeText: String? {
        switch displayState {
        case .text(let t, _), .markdown(let t, _, _): String(t.prefix(200))
        default: nil
        }
    }

    /// The text the text view shows (rendered Markdown's visible text; tests).
    var shownText: String { textView.text }
    var modeControlHidden: Bool { modeControl.isHidden }
    var modeLabels: [String] { (0..<modeControl.segmentCount).map { modeControl.label(forSegment: $0) ?? "" } }
    /// Image placeholders still waiting (tests).
    var pendingImageCount: Int {
        guard let storage = textView.textView.textStorage else { return 0 }
        var n = 0
        storage.enumerateAttribute(.macxImage, in: NSRange(location: 0, length: storage.length)) { v, _, _ in if v != nil { n += 1 } }
        return n
    }
    var imageAttachmentCount: Int {
        guard let storage = textView.textView.textStorage else { return 0 }
        var n = 0
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { v, _, _ in if v != nil { n += 1 } }
        return n
    }

    // MARK: Zoom (text, Markdown, reflowed documents)

    /// The preview shows text the zoom commands apply to.
    var canZoom: Bool {
        guard isActive, isViewLoaded else { return false }
        return Self.zooms(displayState)
    }

    private static func zooms(_ state: DisplayState) -> Bool {
        switch state {
        case .text, .markdown, .document(_, reflowed: true): true
        default: false
        }
    }

    var zoom: Double { context.environment.settings.previewZoom }

    func zoomIn() { setZoom(Self.zoomSteps.first { $0 > zoom + 0.001 } ?? Self.zoomSteps.last!) }
    func zoomOut() { setZoom(Self.zoomSteps.last { $0 < zoom - 0.001 } ?? Self.zoomSteps.first!) }
    func resetZoom() { setZoom(1) }

    /// Sets and remembers the zoom (every text preview, every window).
    func setZoom(_ value: Double) {
        let clamped = min(max(value, Double(TextPreviewView.minimumZoom)), Double(TextPreviewView.maximumZoom))
        let settings = context.environment.settings
        if abs(settings.previewZoom - clamped) > 0.001 { settings.previewZoom = clamped }
        guard isViewLoaded else { return }
        textView.setZoom(CGFloat(clamped))
        updateZoomButton(for: displayState)
    }

    private func updateZoomButton(for state: DisplayState) {
        let zoom = context.environment.settings.previewZoom
        zoomButton.title = NumberFormatter.localizedString(from: NSNumber(value: zoom), number: .percent)
        zoomButton.isHidden = !Self.zooms(state) || abs(zoom - 1) < 0.001
    }

    var zoomLabel: String? { zoomButton.isHidden ? nil : zoomButton.title }
    var expandButtonHidden: Bool { expandButton.isHidden }

    @objc func macx_previewZoomIn(_ sender: Any?) { zoomIn() }
    @objc func macx_previewZoomOut(_ sender: Any?) { zoomOut() }
    @objc func macx_previewActualSize(_ sender: Any?) { resetZoom() }
    @objc private func openQuickLookWindow() { onOpenQuickLook?() }

    // MARK: Rendered | Source, Reflowed | Original

    private func showModeControl(_ first: String, _ second: String, first selected: Bool) {
        modeControl.setLabel(first, forSegment: 0)
        modeControl.setLabel(second, forSegment: 1)
        modeControl.selectedSegment = selected ? 0 : 1
        modeControl.isHidden = false
    }

    @objc private func modeChanged() {
        let first = modeControl.selectedSegment == 0
        switch displayState {
        case .markdown: setMarkdownRendered(first)
        case .document: setDocumentReflowed(first)
        default: break
        }
    }

    /// The Reflowed | Original switch (remembered for every document): shows the selected item again.
    func setDocumentReflowed(_ reflowed: Bool) {
        let settings = context.environment.settings
        if settings.previewReflowsDocuments != reflowed { settings.previewReflowsDocuments = reflowed }
        if case .document = displayState { scheduleUpdate(immediate: true, force: true) }
    }

    /// Reads the document on the read lanes, converts it off the main thread and shows its text reflowed; Quick
    /// Look when the switch says Original or AppKit can't read it.
    private func showDocument(_ url: URL, gen: Int) async {
        guard context.environment.settings.previewReflowsDocuments else {
            if host.shownURL == url { host.refresh() } else { host.show(url) }
            render(.document(url, reflowed: false))
            return
        }
        render(.loading)
        let env = context.environment
        let volume = env.volumes.volume(for: url)?.id ?? .unknown
        let data = await PreviewFiles.read(url, limit: Int(PreviewPlanner.documentByteLimit), lanes: env.lanes, volume: volume)
        let type = env.types.type(at: env.types.index(forExtension: Substring(url.pathExtension), isDirectory: false))
        let text: NSAttributedString? = if let data { await DocumentReflow.convert(data, type: type) } else { nil }
        guard gen == generation, isActive else { return }
        guard let text, text.length > 0 else {
            // Not readable as text (or empty): Quick Look's view, without a switch to flip.
            if host.shownURL == url { host.refresh() } else { host.show(url) }
            render(.quickLook(url))
            return
        }
        host.show(nil)
        documentText = text
        render(.document(url, reflowed: true))
    }

    // MARK: Markdown

    /// The Rendered | Source switch (remembered for every Markdown file).
    func setMarkdownRendered(_ rendered: Bool) {
        let settings = context.environment.settings
        if settings.previewRendersMarkdown != rendered { settings.previewRendersMarkdown = rendered }
        if case .markdown = displayState { render(displayState) }
    }

    /// A click on a link in rendered Markdown. Web and mail links open in their app, `#heading` scrolls, a relative
    /// path selects that item in the window, and a remote image placeholder loads that image.
    @discardableResult
    func followLink(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case MarkdownRenderer.anchorScheme:
            let slug = url.absoluteString.dropFirst(MarkdownRenderer.anchorScheme.count + 1)
            return textView.scrollToAnchor(String(slug).removingPercentEncoding ?? String(slug))
        case MarkdownRenderer.loadImageScheme:
            guard let index = Int(url.absoluteString.dropFirst(MarkdownRenderer.loadImageScheme.count + 1)),
                  index < markdownImages.count else { return false }
            loadRemoteImage(markdownImages[index])
            return true
        case "http", "https", "mailto":
            openExternal(url)
            return true
        case "file":
            onRevealFile?(url)
            return onRevealFile != nil
        default:
            return false
        }
    }

    private func loadLocalImages(_ images: [MarkdownImage]) {
        let local = images.filter { !$0.isRemote }
        guard !local.isEmpty else { return }
        let env = context.environment
        let gen = generation
        imageTask = Task { [weak self] in
            for image in local {
                let volume = env.volumes.volume(for: image.url)?.id ?? .unknown
                let data = await MarkdownFiles.loadImage(image.url, lanes: env.lanes, volume: volume)
                guard let self, !Task.isCancelled, gen == self.generation else { return }
                if let data, let picture = NSImage(data: data) { self.textView.replaceImage(image.index, with: picture) }
            }
        }
    }

    private func loadRemoteImage(_ image: MarkdownImage) {
        let gen = generation
        let fetch = fetchRemoteImage
        Task { [weak self] in
            let data = await fetch(image.url)
            guard let self, gen == self.generation, case .markdown = self.displayState else { return }
            if let data, let picture = NSImage(data: data) { self.textView.replaceImage(image.index, with: picture) }
        }
    }

    /// One remote image, only after a click: an ephemeral session (no cookies or cache), http(s) only, ≤ 16 MB.
    nonisolated static func download(_ url: URL) async -> Data? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpCookieAcceptPolicy = .never
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false,
              data.count <= MarkdownFiles.imageByteLimit else { return nil }
        return data
    }
}

/// The zoom items when the preview's text has focus (the pane is then in the responder chain before any browser pane).
extension PreviewPaneController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(macx_previewZoomIn(_:)), #selector(macx_previewZoomOut(_:)), #selector(macx_previewActualSize(_:)): canZoom
        default: true
        }
    }
}
