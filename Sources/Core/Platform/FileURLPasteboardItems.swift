import AppKit
import Foundation

/// One `public.file-url` pasteboard item per URL (§5.6), shared by copy/cut (`SystemPasteboard`) and drags
/// (`DragPasteboard`).
///
/// Pasteboard decision (overview §4.4, 2026-11-03): the pasteboard server costs ~0.1 ms per eagerly written item
/// and grows super-linearly, so up to `eagerLimit` URLs the data is written immediately; above it each item's
/// file URL is promised and supplied on request by a `FileURLPasteboardProvider` (AppKit also asks for every
/// promised value when the app terminates, so the contents survive a quit). Budgets: ≤10k < 300 ms, 100k < 1.5 s.
@MainActor public enum FileURLPasteboardItems {
    public static let eagerLimit = 5_000

    /// `provider`'s URLs while `pasteboard` still holds what was written at `changeCount`, else nil.
    public static func ownURLs(_ pasteboard: NSPasteboard, provider: FileURLPasteboardProvider?, changeCount: Int) -> [URL]? {
        guard let provider, pasteboard.changeCount == changeCount else { return nil }
        return provider.urls
    }

    /// Items in `urls` order, plus the provider that answers for them (nil when every item is eager). The caller
    /// keeps the provider until the pasteboard's contents change.
    public static func make(_ urls: [URL]) -> (items: [NSPasteboardItem], provider: FileURLPasteboardProvider?) {
        let strings = urls.map { $0.absoluteURL.absoluteString }
        guard urls.count > eagerLimit else {
            return (strings.map { string in
                let item = NSPasteboardItem()
                item.setString(string, forType: .fileURL)
                return item
            }, nil)
        }
        let items = strings.map { _ in NSPasteboardItem() }
        let provider = FileURLPasteboardProvider(urls: urls, strings: strings, items: items)
        for item in items { item.setDataProvider(provider, forTypes: [.fileURL]) }
        return (items, provider)
    }
}

/// Supplies the promised `public.file-url` string of each item. Immutable after init.
public final class FileURLPasteboardProvider: NSObject, NSPasteboardItemDataProvider, Sendable {
    /// The URLs written. Reading promised items back costs a pasteboard round trip per item (~2 ms), so this
    /// process reads its own unchanged contents from here instead (see `ownURLs`).
    public let urls: [URL]
    private let strings: [String]
    private let indexByItem: [ObjectIdentifier: Int]

    init(urls: [URL], strings: [String], items: [NSPasteboardItem]) {
        self.urls = urls
        self.strings = strings
        var index: [ObjectIdentifier: Int] = [:]
        index.reserveCapacity(items.count)
        for (i, item) in items.enumerated() { index[ObjectIdentifier(item)] = i }
        indexByItem = index
    }

    public func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .fileURL, let i = indexByItem[ObjectIdentifier(item)] else { return }
        item.setString(strings[i], forType: .fileURL)
    }
}
