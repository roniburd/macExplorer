import AppKit
import QuickLookUI

/// What the preview pane shows Quick Look previews in (P3-12). Tests use FakeQuickLookHost, so no previewer reads a file.
@MainActor protocol QuickLookHosting: AnyObject {
    var view: NSView { get }
    var shownURL: URL? { get }
    func show(_ url: URL?)
    func close()
}

/// An embedded `QLPreviewView`.
@MainActor final class QLPreviewViewHost: QuickLookHosting {
    private let preview: QLPreviewView
    private(set) var shownURL: URL?
    var view: NSView { preview }

    init() {
        preview = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        preview.shouldCloseWithWindow = false
        preview.autostarts = true
    }

    /// Only called after PreviewPlanner confirmed (on a lane) that the item exists and is not dataless (§4.4).
    func show(_ url: URL?) {
        guard url != shownURL else { return }
        shownURL = url
        preview.previewItem = url as NSURL?
    }

    func close() {
        shownURL = nil
        preview.previewItem = nil
        preview.close()
    }
}

/// Records what the pane asked Quick Look to show; never previews anything.
@MainActor final class FakeQuickLookHost: QuickLookHosting {
    let view = NSView()
    private(set) var shownURL: URL?
    private(set) var history: [URL?] = []
    func show(_ url: URL?) { shownURL = url; history.append(url) }
    func close() { shownURL = nil }
}
