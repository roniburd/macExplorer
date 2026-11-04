// Sources/UI/DragDrop/DragSource.swift
import AppKit
import Core
import MacxFS

/// Drag pasteboard payload (§5.6): every URL as its own public.file-url item (the legacy NSFilenamesPboardType path
/// list is derived from them by the pasteboard), and the secondary-drag marker for right-drags.
@MainActor
enum DragPasteboard {
    static let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    static let secondaryType = NSPasteboard.PasteboardType(DropPolicy.secondaryDragType)

    /// One public.file-url item per URL (promised above the eager limit). The pasteboard synthesizes
    /// NSFilenamesPboardType from file-URL items, so writing it explicitly too would only double the cost.
    /// Above FileURLPasteboardItems.eagerLimit the file URLs are promised; this provider answers for the drag in
    /// progress (kept until the next drag).
    private static var provider: FileURLPasteboardProvider?
    private static var providerPasteboard: NSPasteboard.Name?
    private static var providerChangeCount = 0

    static func write(_ urls: [URL], secondary: Bool, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let (items, provider) = FileURLPasteboardItems.make(urls)
        Self.provider = provider
        pasteboard.writeObjects(items)
        if secondary { pasteboard.setData(Data(), forType: secondaryType) }
        providerPasteboard = pasteboard.name
        providerChangeCount = pasteboard.changeCount
    }

    /// File URL items first: the NSFilenamesPboardType list synthesized from promised items costs a round trip
    /// per item, while reading the items themselves does not.
    static func readURLs(from pasteboard: NSPasteboard) -> [URL] {
        if pasteboard.name == providerPasteboard,
           let own = FileURLPasteboardItems.ownURLs(pasteboard, provider: provider, changeCount: providerChangeCount) {
            return own                          // internal drop of our own promised drag
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls
        }
        let paths = pasteboard.propertyList(forType: filenamesType) as? [String] ?? []
        return paths.map { URL(filePath: $0) }
    }

    static func isSecondary(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.types?.contains(secondaryType) ?? false
    }
}

/// Up to 5 fanned icons plus a red count badge when more than one item is dragged.
@MainActor
enum DragImageComposer {
    static func image(icons: [CGImage], count: Int, iconPoints: CGFloat = 48, scale: CGFloat = 2) -> NSImage {
        let shown = Array(icons.prefix(5))
        let step: CGFloat = 6
        let fan = step * CGFloat(max(shown.count - 1, 0))
        let size = NSSize(width: iconPoints + fan + 22, height: iconPoints + fan + 22)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return NSImage(size: size)
        }
        context.scaleBy(x: scale, y: scale)
        for (index, icon) in shown.enumerated().reversed() {
            context.draw(icon, in: CGRect(x: CGFloat(index) * step, y: fan - CGFloat(index) * step, width: iconPoints, height: iconPoints))
        }
        if count > 1 {
            let graphics = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            let text = count.formatted() as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.white]
            let textSize = text.size(withAttributes: attributes)
            let width = max(textSize.width + 10, 20)
            let badge = NSRect(x: size.width - width, y: size.height - 20, width: width, height: 20)
            NSColor.systemRed.setFill()
            NSBezierPath(roundedRect: badge, xRadius: 10, yRadius: 10).fill()
            text.draw(at: NSPoint(x: badge.midX - textSize.width / 2, y: badge.midY - textSize.height / 2), withAttributes: attributes)
            NSGraphicsContext.restoreGraphicsState()
        }
        guard let image = context.makeImage() else { return NSImage(size: size) }
        return NSImage(cgImage: image, size: size)
    }
}

/// Starts drags from a list. The session begins with ≤ 5 dragging items, and the full URL list is written in
/// willBeginAt so 100k-item drags stay within budget (§5.6, §4.4).
@MainActor
final class DragSourceController: NSObject, NSDraggingSource {
    private let icons: IconCache
    private var pendingURLs: [URL] = []
    private var pendingSecondary = false
    private(set) var isDragging = false

    init(icons: IconCache) {
        self.icons = icons
        super.init()
    }

    func begin(event: NSEvent, rows: IndexSet, folder: FolderModel, view: NSView, rowFrame: (Int) -> NSRect, secondary: Bool) {
        let valid = rows.filteredIndexSet { $0 < folder.rowCount }
        guard !valid.isEmpty, !isDragging else { return }
        let urls = valid.map { folder.url(atRow: $0) }
        pendingURLs = urls
        pendingSecondary = secondary
        isDragging = true
        let sample = Array(valid.prefix(5))
        let scale = Double(view.window?.backingScaleFactor ?? 2)
        let composite = DragImageComposer.image(icons: sample.map { icons.typeIcon(folder.entry(atRow: $0).typeIndex, points: 48, scale: scale) },
                                                count: urls.count, scale: CGFloat(scale))
        let items: [NSDraggingItem] = sample.enumerated().map { index, row in
            let item = NSDraggingItem(pasteboardWriter: urls[index] as NSURL)
            let origin = rowFrame(row).origin
            if index == 0 {
                item.setDraggingFrame(NSRect(origin: origin, size: composite.size), contents: composite)
            } else {
                item.setDraggingFrame(NSRect(origin: origin, size: NSSize(width: 1, height: 1)), contents: nil)
            }
            return item
        }
        let session = view.beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .move, .link, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        DragPasteboard.write(pendingURLs, secondary: pendingSecondary, to: session.draggingPasteboard)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        pendingURLs = []
        isDragging = false
    }
}
