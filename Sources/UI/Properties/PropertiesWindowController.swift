// Sources/UI/Properties/PropertiesWindowController.swift
import AppKit
import SwiftUI
import Core
import MacxFS

/// Non-modal Properties window (§5.8). One per selection set (a second ⌘I on the same set focuses it), undo through
/// the app-wide FileOpUndoStack (§6.6), edits as jobs whose errors are shown inline.
@MainActor
final class PropertiesWindowController: NSWindowController, NSWindowDelegate {
    private struct Key: Hashable {
        enum Subject: Hashable { case items(Set<URL>), volume(VolumeID) }
        let context: ObjectIdentifier
        let subject: Subject
    }

    private static var registry: [Key: PropertiesWindowController] = [:]
    private static var cascadePoint = NSPoint.zero

    let context: UIContext
    let model: PropertiesViewModel
    private var key: Key
    private var fieldEditorUndo: UndoManager?

    static func show(for urls: [URL], context: UIContext) {
        controller(for: .items(urls), context: context, activate: true)
    }

    static func show(volume: VolumeInfo, context: UIContext) {
        controller(for: .volume(volume), context: context, activate: true)
    }

    /// The window for `subject`, created and loaded on first use. `activate: false` never orders it front (tests, S5-C7).
    @discardableResult
    static func controller(for subject: PropertiesSubject, context: UIContext, activate: Bool) -> PropertiesWindowController? {
        let subject = normalized(subject)
        guard let key = key(for: subject, context: context) else { return nil }
        let controller: PropertiesWindowController
        if let existing = registry[key] {
            controller = existing
        } else {
            controller = PropertiesWindowController(subject: subject, context: context, key: key)
            registry[key] = controller
            Task { await controller.loadContent() }
        }
        if activate {
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
        }
        return controller
    }

    static func openControllers(for context: UIContext) -> [PropertiesWindowController] {
        registry.filter { $0.key.context == ObjectIdentifier(context) }.map(\.value)
    }

    static func closeAll(for context: UIContext) {
        for controller in openControllers(for: context) { controller.close() }
    }

    /// P1-38's router answers job errors from these windows with Skip; the window shows them inline (§5.8).
    static func answersErrorsInline(_ origin: OriginID) -> Bool {
        registry.values.contains { $0.model.origin == origin }
    }

    private static func normalized(_ subject: PropertiesSubject) -> PropertiesSubject {
        switch subject {
        case .items(let urls): .items(urls.map(\.standardizedFileURL))
        case .volume: subject
        }
    }

    private static func key(for subject: PropertiesSubject, context: UIContext) -> Key? {
        switch subject {
        case .items(let urls) where urls.isEmpty: nil
        case .items(let urls): Key(context: ObjectIdentifier(context), subject: .items(Set(urls)))
        case .volume(let volume): Key(context: ObjectIdentifier(context), subject: .volume(volume.id))
        }
    }

    private init(subject: PropertiesSubject, context: UIContext, key: Key) {
        self.context = context
        self.key = key
        model = PropertiesViewModel(subject: subject, environment: context.environment)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 520),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier(AXID.propertiesWindow)
        window.setAccessibilityIdentifier(AXID.propertiesWindow)
        window.title = model.title
        super.init(window: window)
        window.delegate = self
        model.origin = OriginID(raw: window.windowNumber)
        model.confirm = { [weak self] confirmation in await self?.confirm(confirmation) ?? false }
        model.onSubjectChanged = { [weak self] subject in self?.subjectChanged(subject) }
        let hosting = NSHostingController(rootView: PropertiesView(model: model, actions: makeActions()))
        hosting.sizingOptions = [.preferredContentSize]
        window.contentViewController = hosting
        window.center()
        Self.cascadePoint = window.cascadeTopLeft(from: Self.cascadePoint)
    }

    required init?(coder: NSCoder) { fatalError("PropertiesWindowController is created in code") }

    func loadContent() async {
        await model.load()
        updateIcon()
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        model.close()
        if Self.registry[key] === self { Self.registry[key] = nil }
    }

    /// §6.6: the app-wide stack, or a per-edit manager while the name field is being edited.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor {
            if fieldEditorUndo == nil { fieldEditorUndo = context.environment.undo.makeFieldEditorUndoManager() }
            return fieldEditorUndo
        }
        fieldEditorUndo = nil
        return context.environment.undo.undoManager
    }

    /// ⌘W while a Properties window is key (the browser's handler isn't in this window's responder chain).
    @objc func macx_closeWindow(_ sender: Any?) {
        window?.performClose(sender)
    }

    // MARK: private

    private func subjectChanged(_ subject: PropertiesSubject) {
        if Self.registry[key] === self { Self.registry[key] = nil }
        if let newKey = Self.key(for: subject, context: context) {
            key = newKey
            Self.registry[newKey] = self
        }
        window?.title = model.title
        updateIcon()
    }

    /// Tier 0 type icon at once, then the per-file icon from a lane (S5-C3).
    private func updateIcon() {
        guard case .item(let item) = model.content else { return }
        let scale = Double(window?.backingScaleFactor ?? 2)
        let index = context.environment.types.index(forExtension: Substring(item.url.pathExtension),
                                                    isDirectory: item.kind == .directory || item.kind == .package)
        model.icon = context.icons.typeIcon(index, points: 64, scale: scale)
        context.icons.fileIcon(for: item.url, rowID: .name(item.url.path), points: 64, scale: scale) { [weak self] image in
            self?.model.icon = image
        }
    }

    private func makeActions() -> PropertiesActions {
        PropertiesActions(
            reveal: { [weak self] url in
                _ = self?.context.windows.openWindow(at: url.deletingLastPathComponent(), selecting: url.lastPathComponent)
            },
            changeDefaultApp: { [weak self] allOfType in self?.changeDefaultApp(allOfType: allOfType) },
            eject: { [weak self] in self?.eject() })
    }

    private func changeDefaultApp(allOfType: Bool) {
        guard case .item(let item) = model.content, let window else { return }
        Task {
            await DefaultAppSheet.present(for: item.url, on: window, context: context, alwaysChecked: allOfType, opensFile: false)
            await model.reloadDefaultApp()
        }
    }

    private func eject() {
        Task {
            if await model.eject() { close() }
        }
    }

    private func confirm(_ confirmation: PropertiesConfirmation) async -> Bool {
        switch confirmation {
        case .rename(let prompt):
            return await RenamePrompts.present(prompt, on: window)
        case .applyToEnclosed(let name):
            let alert = NSAlert()
            alert.messageText = String(format: L10n.string("Apply these permissions to all items inside '%@'?"), name)
            alert.informativeText = L10n.string("You can undo this with Edit › Undo.")
            alert.addButton(withTitle: L10n.string("Apply"))
            alert.addButton(withTitle: L10n.string("Cancel"))
            guard let window else { return alert.runModal() == .alertFirstButtonReturn }
            return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
        }
    }
}
