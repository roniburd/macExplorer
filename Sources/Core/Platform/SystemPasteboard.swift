import AppKit
import Foundation

/// NSPasteboard-backed `PasteboardBackend` (§5.6). Writes one `public.file-url` item per URL, with no cap (promised above
/// FileURLPasteboardItems.eagerLimit); the first item also carries (for cut) the private marker and, up to that limit,
/// the legacy NSFilenamesPboardType path list and the paths as plain text.
@MainActor public final class SystemPasteboard: PasteboardBackend {
    public static let cutMarkerType: String = "com.macexplorer.cut"
    static let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    static let markerType = NSPasteboard.PasteboardType(cutMarkerType)

    private let pasteboard: NSPasteboard

    /// nil = .general (app); tests/scenarios pass a private name.
    public init(name: String?) {
        pasteboard = name.map { NSPasteboard(name: NSPasteboard.Name($0)) } ?? .general
    }

    public var changeCount: Int { pasteboard.changeCount }

    /// Answers the promised file URLs of the current contents (above FileURLPasteboardItems.eagerLimit).
    private var provider: FileURLPasteboardProvider?
    private var providerChangeCount = 0

    @discardableResult public func writeFileURLs(_ urls: [URL], cutMarker: Bool) -> Int {
        pasteboard.clearContents()
        provider = nil
        guard !urls.isEmpty else { return pasteboard.changeCount }
        let (items, provider) = FileURLPasteboardItems.make(urls)
        self.provider = provider
        let first = items[0]
        if provider == nil {
            // Above the eager limit the legacy path list and plain text are not written (overview §4.4 decision).
            let paths = urls.map(Self.plainPath)
            first.setPropertyList(paths, forType: Self.filenamesType)
            first.setString(paths.joined(separator: "\n"), forType: .string)
        }
        if cutMarker { first.setData(Data(), forType: Self.markerType) }
        pasteboard.writeObjects(items)
        providerChangeCount = pasteboard.changeCount
        return pasteboard.changeCount
    }

    /// POSIX path without a directory URL's trailing slash ("/" stays "/").
    static func plainPath(_ url: URL) -> String {
        var path = url.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    @discardableResult public func writeString(_ string: String) -> Int {
        pasteboard.clearContents()
        provider = nil
        pasteboard.setString(string, forType: .string)
        return pasteboard.changeCount
    }

    public func readString() -> String? { pasteboard.string(forType: .string) }

    public func readFileURLs() -> [URL] {
        if let own = FileURLPasteboardItems.ownURLs(pasteboard, provider: provider, changeCount: providerChangeCount) { return own }
        var urls: [URL] = []
        for item in pasteboard.pasteboardItems ?? [] {
            guard let string = item.string(forType: .fileURL), let url = URL(string: string), url.isFileURL else { continue }
            urls.append(url)
        }
        if !urls.isEmpty { return urls }
        let paths = pasteboard.propertyList(forType: Self.filenamesType) as? [String] ?? []
        return paths.map { URL(filePath: $0) }
    }

    public func hasFileURLs() -> Bool {
        guard let types = pasteboard.types else { return false }
        return types.contains(.fileURL) || types.contains(Self.filenamesType)
    }

    public func hasCutMarker() -> Bool {
        pasteboard.types?.contains(Self.markerType) ?? false
    }
}
