import AppKit
import UniformTypeIdentifiers
import Core

/// §5.7: checked → set the content-type default (works for dyn.* types), then the per-file default (so an existing
/// per-file override can't keep winning), then open; unchecked → open once with the app.
enum DefaultAppChoice {
    static func apply(app: URL, file: URL, always: Bool, provider: any LaunchServicesProviding) async throws {
        if always {
            try await provider.setDefaultApplication(app, forContentTypeOf: file)
            try await provider.setDefaultApplication(app, forFile: file)
        }
        try await provider.open([file], withApplicationAt: app)
    }

    /// Properties (§5.8): the per-file default, or with `allOfType` the content-type default first, then the per-file
    /// one (so an older per-file override can't keep winning). Opens nothing.
    static func setDefault(app: URL, file: URL, allOfType: Bool, provider: any LaunchServicesProviding) async throws {
        if allOfType { try await provider.setDefaultApplication(app, forContentTypeOf: file) }
        try await provider.setDefaultApplication(app, forFile: file)
    }
}

/// Choose Default App… sheet: the apps that can open the file, Browse…, and "Always use this app".
@MainActor
final class DefaultAppSheet: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let file: URL
    private let context: UIContext
    private var apps: [AppInfo] = []
    private let panel: NSPanel
    private let table = NSTableView()
    private let always: NSButton
    private let opensFile: Bool
    private var continuation: CheckedContinuation<AppInfo?, Never>?

    static func present(for file: URL, on window: NSWindow, context: UIContext) async {
        await present(for: file, on: window, context: context, alwaysChecked: false, opensFile: true)
    }

    /// Properties' Change All… opens the sheet with the checkbox already on (P1-37).
    static func present(for file: URL, on window: NSWindow, context: UIContext, alwaysChecked: Bool) async {
        await present(for: file, on: window, context: context, alwaysChecked: alwaysChecked, opensFile: true)
    }

    /// `opensFile: false` (Properties' Change… / Change All…): set the default only; the checkbox means "all files
    /// of this type" (§5.8).
    static func present(for file: URL, on window: NSWindow, context: UIContext, alwaysChecked: Bool, opensFile: Bool) async {
        await DefaultAppSheet(file: file, context: context, alwaysChecked: alwaysChecked, opensFile: opensFile).run(on: window)
    }

    private init(file: URL, context: UIContext, alwaysChecked: Bool, opensFile: Bool) {
        self.opensFile = opensFile
        self.file = file
        self.context = context
        let ext = file.pathExtension
        always = NSButton(checkboxWithTitle: ext.isEmpty ? L10n.string("Always use this app to open files of this type")
                                                         : String(format: L10n.string("Always use this app to open .%@ files"), ext),
                          target: nil, action: nil)
        always.state = alwaysChecked ? .on : .off
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 360), styleMask: [.titled], backing: .buffered, defer: true)
        super.init()
        buildUI()
    }

    private func buildUI() {
        let title = NSTextField(labelWithString: String(format: L10n.string("Choose an app to open '%@':"), file.lastPathComponent))
        let column = NSTableColumn(identifier: .init("app"))
        column.title = ""
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openPressed(_:))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.heightAnchor.constraint(equalToConstant: 220).isActive = true
        let browse = NSButton(title: L10n.string("Browse…"), target: self, action: #selector(browsePressed(_:)))
        let cancel = NSButton(title: L10n.string("Cancel"), target: self, action: #selector(cancelPressed(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let open = NSButton(title: L10n.string("Open"), target: self, action: #selector(openPressed(_:)))
        open.keyEquivalent = "\r"
        let buttons = NSStackView(views: [browse, NSView(), cancel, open])
        let stack = NSStackView(views: [title, scroll, always, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for view in [scroll, buttons] { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true }
        panel.contentView = stack
    }

    private func run(on window: NSWindow) async {
        apps = await context.environment.launchServices.provider.applications(toOpen: file)
        table.reloadData()
        if !apps.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        let chosen = await withCheckedContinuation { (continuation: CheckedContinuation<AppInfo?, Never>) in
            self.continuation = continuation
            window.beginSheet(panel)
        }
        window.endSheet(panel)
        guard let chosen else { return }
        let provider = context.environment.launchServices.provider
        do {
            if opensFile {
                try await DefaultAppChoice.apply(app: chosen.url, file: file, always: always.state == .on, provider: provider)
            } else {
                try await DefaultAppChoice.setDefault(app: chosen.url, file: file, allOfType: always.state == .on, provider: provider)
            }
            context.environment.launchServices.invalidate(file: file)
        } catch {
            let alert = NSAlert()
            alert.messageText = opensFile
                ? String(format: L10n.string("'%@' couldn't be opened with %@."), file.lastPathComponent, chosen.name)
                : String(format: L10n.string("The default app for '%@' couldn't be changed."), file.lastPathComponent)
            alert.informativeText = error.localizedDescription
            _ = await alert.beginSheetModal(for: window)
        }
    }

    private func finish(_ app: AppInfo?) {
        continuation?.resume(returning: app)
        continuation = nil
    }

    @objc private func openPressed(_ sender: Any?) {
        let row = table.selectedRow
        finish(row >= 0 && row < apps.count ? apps[row] : nil)
    }

    @objc private func cancelPressed(_ sender: Any?) { finish(nil) }

    @objc private func browsePressed(_ sender: Any?) {
        let open = NSOpenPanel()
        open.allowedContentTypes = [.application]
        open.directoryURL = URL(filePath: "/Applications", directoryHint: .isDirectory)
        let provider = context.environment.launchServices.provider
        Task {
            guard await open.beginSheetModal(for: self.panel) == .OK, let url = open.url else { return }
            let info = await provider.appInfo(at: url) ?? AppInfo(url: url, name: url.deletingPathExtension().lastPathComponent, bundleIdentifier: nil)
            self.apps.insert(info, at: 0)
            self.table.reloadData()
            self.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { apps.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = tableView.makeView(withIdentifier: .init("appName"), owner: nil) as? NSTextField ?? {
            let field = NSTextField(labelWithString: "")
            field.identifier = .init("appName")
            return field
        }()
        label.stringValue = apps[row].name
        return label
    }
}
