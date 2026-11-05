import Foundation

/// The pasteboard as Core sees it (§5.6). `SystemPasteboard` (Core/Platform) wraps NSPasteboard; tests use `InMemoryPasteboard`.
@MainActor public protocol PasteboardBackend: AnyObject {
    var changeCount: Int { get }
    /// One public.file-url item per URL + NSFilenamesPboardType + plain-text paths (+ cut marker). Returns new changeCount.
    @discardableResult func writeFileURLs(_ urls: [URL], cutMarker: Bool) -> Int
    func readFileURLs() -> [URL]
    func hasFileURLs() -> Bool
    func hasCutMarker() -> Bool
    /// Replaces the contents with plain text only (no file URLs, no cut marker), so a later ⌘V pastes no files.
    /// Returns the new changeCount (P2-04, Copy as Path and Copy Path As ▸).
    @discardableResult func writeString(_ string: String) -> Int
    /// The plain-text contents, or nil when the pasteboard holds no text.
    func readString() -> String?
}

/// In-process pasteboard for tests and scenarios. Never touches NSPasteboard.
@MainActor public final class InMemoryPasteboard: PasteboardBackend {
    public private(set) var changeCount = 0
    private var urls: [URL] = []
    private var marker = false
    private var text: String?

    public init() {}

    @discardableResult public func writeFileURLs(_ urls: [URL], cutMarker: Bool) -> Int {
        self.urls = urls
        marker = cutMarker
        text = urls.isEmpty ? nil : urls.map { PathFormatter.posixPath($0) }.joined(separator: "\n")
        changeCount += 1
        return changeCount
    }

    @discardableResult public func writeString(_ string: String) -> Int {
        urls = []
        marker = false
        text = string
        changeCount += 1
        return changeCount
    }

    public func readString() -> String? { text }

    public func readFileURLs() -> [URL] { urls }
    public func hasFileURLs() -> Bool { !urls.isEmpty }
    public func hasCutMarker() -> Bool { marker }

    /// Another app (e.g. Finder) copied `urls`: bumps changeCount, no marker.
    public func simulateExternalCopy(_ urls: [URL]) {
        writeFileURLs(urls, cutMarker: false)
    }
}
