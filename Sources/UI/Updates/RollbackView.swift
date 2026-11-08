import AppKit
import SwiftUI
import Core

/// macExplorer › Install Previous Version… (install-previous-version spec): pick an older release, confirm, and
/// MacExplorer quits and reopens as that version.
struct RollbackView: View {
    @Bindable var model: RollbackModel
    let close: @MainActor () -> Void
    @State private var confirming: AppcastItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("Previous Versions")).font(.headline)
            content.frame(minHeight: 180, alignment: .top)
            HStack {
                Spacer()
                buttons
            }
        }
        .padding(20)
        .frame(width: 460)
        .alert(L10n.string("Install an Older Version?"), isPresented: Binding(
            get: { confirming != nil }, set: { if !$0 { confirming = nil } }), presenting: confirming) { item in
            Button(L10n.string("Cancel"), role: .cancel) {}
            Button(L10n.string("Install and Reopen")) { Task { await model.install(item) } }
        } message: { item in
            Text(String(format: L10n.string("MacExplorer will quit and reopen as %@. Automatic updates skip versions up to %@ until you choose Check for Updates…."),
                        item.version, model.installedVersion))
        }
        .task { await model.load() }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(L10n.string("Loading releases…")) }
        case .empty:
            Text(String(format: L10n.string("No earlier releases are available for %@ on your update channel."), model.installedVersion))
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .list:
            List(selection: $model.selection) {
                Section {
                    ForEach(model.items) { item in
                        row(item).tag(item.id)
                    }
                } header: {
                    Text(String(format: L10n.string("Installed: %@"), model.installedVersion))
                }
            }
            .listStyle(.bordered)
            .accessibilityIdentifier(AXID.rollbackList)
        case .preparing(let item, let fraction):
            VStack(alignment: .leading, spacing: 8) {
                Text(String(format: L10n.string("Downloading MacExplorer %@…"), item.version))
                if let fraction { ProgressView(value: fraction) } else { ProgressView().progressViewStyle(.linear) }
            }
        case .ready(let item):
            Text(String(format: L10n.string("MacExplorer will reopen as %@ when it quits."), item.version))
        }
    }

    private func row(_ item: AppcastItem) -> some View {
        HStack {
            Text(item.version).font(.body.monospacedDigit())
            if let date = item.pubDate {
                Text(date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
            }
            Spacer()
            if let notes = item.notesURL {
                Button(L10n.string("Notes ↗")) { NSWorkspace.shared.open(notes) }.buttonStyle(.link)
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        switch model.phase {
        case .list:
            Button(L10n.string("Cancel"), action: close).keyboardShortcut(.cancelAction)
            Button(L10n.string("Install…")) { confirming = model.selectedItem }
                .keyboardShortcut(.defaultAction)
                .disabled(model.selectedItem == nil)
                .accessibilityIdentifier(AXID.rollbackInstall)
        case .ready:
            Button(L10n.string("Cancel Install")) { model.cancelInstall() }
            Button(L10n.string("Quit Now")) { model.quitNow() }.keyboardShortcut(.defaultAction)
        case .failed:
            Button(L10n.string("Close"), action: close).keyboardShortcut(.cancelAction)
            Button(L10n.string("Try Again")) { model.backToList() }.keyboardShortcut(.defaultAction)
        case .preparing:
            Button(L10n.string("Cancel")) {}.disabled(true)
        case .loading, .empty:
            Button(L10n.string("Close"), action: close).keyboardShortcut(.cancelAction)
        }
    }
}

/// One Install Previous Version window per app. Closing it disarms an armed (not yet swapped) rollback.
@MainActor
final class RollbackWindowController: NSWindowController, NSWindowDelegate {
    private static var current: RollbackWindowController?
    private let model: RollbackModel

    static func show(service: any RollbackServicing) {
        let controller = current ?? RollbackWindowController(model: RollbackModel(service: service))
        current = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init(model: RollbackModel) {
        self.model = model
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        super.init(window: window)
        let view = RollbackView(model: model, close: { [weak window] in window?.performClose(nil) })
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        window.contentViewController = host
        window.title = L10n.string("Previous Versions")
        window.setAccessibilityIdentifier(AXID.rollbackWindow)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.center()
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("RollbackWindowController is created in code") }

    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.isBusy }

    func windowWillClose(_ notification: Notification) {
        model.cancelInstall()
        if Self.current === self { Self.current = nil }
    }
}

extension UpdateModel {
    /// macExplorer › Install Previous Version…: false when the updater or its rollback service is off.
    @discardableResult
    public func showInstallPreviousVersion() -> Bool {
        guard let service = rollbackService else { return false }
        RollbackWindowController.show(service: service)
        return true
    }
}
