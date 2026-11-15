import AppKit
@testable import UI

/// Records what the pane asked Quick Look to show; never previews anything.
@MainActor final class FakeQuickLookHost: QuickLookHosting {
    let view = NSView()
    private(set) var shownURL: URL?
    private(set) var history: [URL?] = []
    private(set) var refreshes = 0
    func show(_ url: URL?) { shownURL = url; history.append(url) }
    func refresh() { if shownURL != nil { refreshes += 1 } }
    func close() { shownURL = nil }
}
