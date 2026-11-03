import AppKit
import Foundation

/// NSPasteboard-backed `PasteboardBackend` (§5.6). Writes one `public.file-url` item per URL, with no cap; the first
/// item also carries the legacy NSFilenamesPboardType path list, the paths as plain text and (for cut) the private marker.
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

    @discardableResult public func writeFileURLs(_ urls: [URL], cutMarker: Bool) -> Int {
        pasteboard.clearContents()
        guard !urls.isEmpty else { return pasteboard.changeCount }
        var items: [NSPasteboardItem] = []
        items.reserveCapacity(urls.count)
        for url in urls {
            let item = NSPasteboardItem()
            item.setString(url.absoluteURL.absoluteString, forType: .fileURL)
            items.append(item)
        }
        let paths = urls.map(Self.plainPath)
        let first = items[0]
        first.setPropertyList(paths, forType: Self.filenamesType)
        first.setString(paths.joined(separator: "\n"), forType: .string)
        if cutMarker { first.setData(Data(), forType: Self.markerType) }
        pasteboard.writeObjects(items)
        return pasteboard.changeCount
    }

    /// POSIX path without a directory URL's trailing slash ("/" stays "/").
    static func plainPath(_ url: URL) -> String {
        var path = url.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    public func readFileURLs() -> [URL] {
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
