import AppKit
import SwiftUI
import Core
import MacxFS

/// Rename N Items (P4-12, spec §11 "Batch rename"): a sheet on the browser window with the rules on top and the live
/// preview below. Rename runs one `.batchRename` job (one undo) and closes the sheet; Cancel or Esc changes nothing.
@MainActor
final class BatchRenameSheet {
    let model: BatchRenameModel
    let panel: NSPanel
    private weak var parent: NSWindow?
    private static var open: [ObjectIdentifier: BatchRenameSheet] = [:]

    private init(model: BatchRenameModel) {
        self.model = model
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 520), styleMask: [.titled, .resizable],
                        backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.title = model.title
        panel.minSize = NSSize(width: 520, height: 420)
        let view = BatchRenameView(model: model, rename: { [weak self] in self?.rename() }, cancel: { [weak self] in self?.cancel() })
        let host = NSHostingController(rootView: view)
        host.title = model.title
        panel.contentViewController = host
        panel.setContentSize(NSSize(width: 620, height: 520))
    }

    /// Opens the sheet for `urls` (display order). One sheet per window: a second request while one is up does nothing.
    @discardableResult
    static func present(for urls: [URL], folder: FolderModel, on window: NSWindow, context: UIContext,
                        origin: OriginID?) -> BatchRenameSheet? {
        guard urls.count > 1, open[ObjectIdentifier(window)] == nil else { return nil }
        let model = BatchRenameModel(urls: urls, folder: folder, context: context, origin: origin)
        return present(model, on: window)
    }

    /// Search results (several folders): no folder snapshot, so a name taken in some folder is only found when the
    /// job runs, which then picks the next free name (it never overwrites).
    @discardableResult
    static func present(for urls: [URL], caseSensitive: Bool, on window: NSWindow, context: UIContext,
                        origin: OriginID?) -> BatchRenameSheet? {
        guard urls.count > 1, open[ObjectIdentifier(window)] == nil else { return nil }
        let operations = context.environment.operations
        let model = BatchRenameModel(urls: BatchRenameModel.planningURLs(urls), existingNames: [], caseSensitive: caseSensitive,
                                     origin: origin, perform: { await operations.perform($0) })
        return present(model, on: window)
    }

    private static func present(_ model: BatchRenameModel, on window: NSWindow) -> BatchRenameSheet {
        let sheet = BatchRenameSheet(model: model)
        sheet.parent = window
        open[ObjectIdentifier(window)] = sheet
        window.beginSheet(sheet.panel) { _ in
            MainActor.assumeIsolated { open[ObjectIdentifier(window)] = nil }
        }
        sheet.focusFindField()
        return sheet
    }

    /// The sheet open on `window`, if any.
    static func current(on window: NSWindow?) -> BatchRenameSheet? {
        window.flatMap { open[ObjectIdentifier($0)] }
    }

    func cancel() { close() }

    /// The Find field takes the keyboard when the sheet opens (also its initial first responder).
    private func focusFindField() {
        panel.contentView?.layoutSubtreeIfNeeded()
        guard let field = Self.firstTextField(in: panel.contentView) else { return }
        panel.initialFirstResponder = field
        panel.makeFirstResponder(field)
    }

    private static func firstTextField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable { return field }
        for sub in view.subviews { if let found = firstTextField(in: sub) { return found } }
        return nil
    }

    /// The Rename button (Return): waits for a preview still being computed (Return right after typing), then runs the
    /// job and closes the sheet; a preview that blocks keeps the sheet open (beep).
    func rename() {
        let model = self.model
        renameTask = Task { [weak self] in
            await model.waitForPreview()
            guard model.canApply else { NSSound.beep(); return }
            self?.close()
            _ = await model.apply()
        }
    }

    /// Tests: the Rename press in flight.
    private(set) var renameTask: Task<Void, Never>?

    private func close() {
        if let parent, panel.sheetParent === parent { parent.endSheet(panel) } else { panel.orderOut(nil) }
    }
}

/// The sheet's SwiftUI content.
struct BatchRenameView: View {
    @Bindable var model: BatchRenameModel
    var rename: () -> Void
    var cancel: () -> Void

    private var numberingOn: Binding<Bool> {
        Binding(get: { model.rules.numbering != nil },
                set: { model.rules.numbering = $0 ? (model.rules.numbering ?? BatchRenameRules.Numbering()) : nil })
    }

    private func numbering<T>(_ keyPath: WritableKeyPath<BatchRenameRules.Numbering, T>) -> Binding<T> {
        Binding(get: { (model.rules.numbering ?? BatchRenameRules.Numbering())[keyPath: keyPath] },
                set: { var n = model.rules.numbering ?? BatchRenameRules.Numbering(); n[keyPath: keyPath] = $0; model.rules.numbering = n })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.title).font(.headline)
            Form {
                TextField(L10n.string("Find:"), text: $model.rules.find)
                    .accessibilityIdentifier("macx.batchRename.find")
                TextField(L10n.string("Replace with:"), text: $model.rules.replace)
                    .accessibilityIdentifier("macx.batchRename.replace")
                HStack {
                    Toggle(L10n.string("Regular expression"), isOn: $model.rules.useRegex)
                        .accessibilityIdentifier("macx.batchRename.regex")
                    Toggle(L10n.string("Match case"), isOn: $model.rules.caseSensitive)
                }
                TextField(L10n.string("Prefix:"), text: $model.rules.prefix)
                TextField(L10n.string("Suffix:"), text: $model.rules.suffix)
                Picker(L10n.string("Case:"), selection: $model.rules.caseChange) {
                    Text(L10n.string("Don't Change")).tag(BatchRenameRules.CaseChange.none)
                    Text(L10n.string("lowercase")).tag(BatchRenameRules.CaseChange.lower)
                    Text(L10n.string("UPPERCASE")).tag(BatchRenameRules.CaseChange.upper)
                    Text(L10n.string("Title Case")).tag(BatchRenameRules.CaseChange.title)
                    Text(L10n.string("Sentence case")).tag(BatchRenameRules.CaseChange.sentence)
                }
                Picker(L10n.string("Apply to:"), selection: $model.rules.scope) {
                    Text(L10n.string("Name")).tag(BatchRenameRules.Scope.baseName)
                    Text(L10n.string("Name and extension")).tag(BatchRenameRules.Scope.wholeName)
                    Text(L10n.string("Extension")).tag(BatchRenameRules.Scope.extensionOnly)
                }
                .pickerStyle(.segmented)
                Toggle(L10n.string("Add numbers"), isOn: numberingOn)
                if model.rules.numbering != nil {
                    Picker(L10n.string("Position:"), selection: numbering(\.position)) {
                        Text(L10n.string("Before")).tag(BatchRenameRules.Numbering.Position.prefix)
                        Text(L10n.string("After")).tag(BatchRenameRules.Numbering.Position.suffix)
                        Text(L10n.string("Replace name")).tag(BatchRenameRules.Numbering.Position.replaceName)
                    }
                    if model.rules.numbering?.position == .replaceName {
                        TextField(L10n.string("Base name:"), text: numbering(\.baseName))
                    } else {
                        TextField(L10n.string("Separator:"), text: numbering(\.separator))
                    }
                    HStack {
                        TextField(L10n.string("Start at:"), value: numbering(\.start), format: .number)
                        TextField(L10n.string("Step:"), value: numbering(\.step), format: .number)
                        TextField(L10n.string("Digits:"), value: numbering(\.minDigits), format: .number)
                    }
                }
            }
            BatchRenamePreviewTable(rows: model.preview?.rows ?? [])
                .frame(minHeight: 160)
            HStack {
                Spacer()
                Button(L10n.string("Cancel"), action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("macx.batchRename.cancel")
                Button(L10n.string("Rename"), action: rename)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canApply && !model.isComputing)   // Return right after typing waits for the preview
                    .accessibilityIdentifier("macx.batchRename.apply")
            }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 420)
    }
}
