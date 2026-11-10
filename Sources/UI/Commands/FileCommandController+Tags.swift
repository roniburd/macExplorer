import AppKit
import Core

/// Tags (P4-05): Edit Tags… opens the tag editor in a popover; the Tags ▸ submenus and the editor run their edits
/// through `applyTagEdit`.
extension FileCommandController {
    /// One undoable `setTags` job over `urls`, then the tag goes to the front of the known tags (add and toggle).
    func applyTagEdit(_ edit: TagEdit, to urls: [URL]) async {
        guard !urls.isEmpty else { return }
        _ = await run(.setTags(urls, edit))
        switch edit {
        case .add(let tag), .toggle(let tag): environment.settings.noteTagUsed(tag)
        case .remove, .set: break
        }
    }

    /// Edit Tags…: the editor in a popover at the first selected row (or the list / window when there's no row).
    func editTags(_ target: CommandTarget) {
        let urls = subjectURLs(target)
        guard !urls.isEmpty, let (rect, view) = tagPopoverAnchor(target) else { return }
        tagPopover?.close()
        let model = TagEditorModel(urls: urls, context: context)
        let origin = window?.origin
        let operations = environment.operations
        model.perform = { kind in await operations.perform(JobRequest(kind, origin: origin)) }
        let controller = TagEditorPopoverController(model: model)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.delegate = controller
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        tagPopover = popover
    }

    private func tagPopoverAnchor(_ target: CommandTarget) -> (NSRect, NSView)? {
        if let content = contentController() {
            let list = content.activeList
            let row: Int? = switch target {
            case .contentSelection(let folder) where list.source === folder:
                folder.selection.cursor.flatMap { folder.row(of: $0) }.flatMap { folder.selection.rows.contains($0) ? $0 : nil }
                    ?? folder.selection.rows.first
            case .resultsSelection(let results) where list.source === results:
                results.selection.cursor.flatMap { results.row(of: $0) }.flatMap { results.selection.rows.contains($0) ? $0 : nil }
                    ?? results.selection.rows.first
            default: nil
            }
            if let row, let screen = (list as? QuickLookSourceList)?.quickLookSourceFrame(forModelRow: row),
               let host = window?.window, let view = host.contentView {
                return (view.convert(host.convertFromScreen(screen), from: nil), view)
            }
            if case .folder = target, let view = window?.window?.contentView { return (view.bounds, view) }
            return (content.listContainer.bounds, content.listContainer)
        }
        guard let view = window?.window?.contentView else { return nil }
        return (view.bounds, view)
    }
}
