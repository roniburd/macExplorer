// Sources/UI/DragDrop/DragSource.swift
import AppKit
import Core
import MacxFS
import MacxPluginKit

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
    /// A drag of remote rows (file promises, copy only; spec §4.5) is in progress.
    private var pendingRemote = false
    private var promiseDelegate: RemoteFilePromiseDelegate?
    private let environment: CoreEnvironment?
    private(set) var isDragging = false
    /// The session `begin` started; only its `endedAt` ends the drag (an older session's late callback doesn't).
    private var session: AnyObject?
    /// Starts the AppKit session (tests replace it: a real session would run a drag loop). Nil: no session started.
    var startSession: @MainActor (_ view: NSView, _ items: [NSDraggingItem], _ event: NSEvent,
                                  _ source: DragSourceController) -> AnyObject? = { view, items, event, source in
        let session = view.beginDraggingSession(with: items, event: event, source: source)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
        return session
    }

    /// `environment` is needed only for drags out of repository folders (nil: remote rows can't be dragged).
    init(icons: IconCache, environment: CoreEnvironment? = nil) {
        self.icons = icons
        self.environment = environment
        super.init()
    }

    /// A new mouse press: whatever drag this controller started is over (AppKit doesn't deliver presses to the view
    /// while one of its sessions runs). Clears a drag that never got a session going, so it can't block every later
    /// drag from this view.
    func pressBegan() {
        guard isDragging else { return }
        endDrag()
    }

    private func endDrag() {
        pendingURLs = []
        pendingRemote = false
        isDragging = false
        session = nil
    }

    private func start(_ items: [NSDraggingItem], view: NSView, event: NSEvent) {
        guard let started = startSession(view, items, event, self) else {
            NSLog("MacExplorer couldn't start a drag from %@", String(describing: type(of: view)))
            return endDrag()
        }
        session = started
    }

    func begin(event: NSEvent, rows: IndexSet, source: any RowSource, view: NSView, rowFrame: (Int) -> NSRect, secondary: Bool) {
        let valid = rows.filteredIndexSet { $0 < source.rowCount }
        guard !valid.isEmpty else { return }
        if let folder = source as? FolderModel, folder.isRemote {
            if let environment {
                beginRemote(event: event, rows: Array(valid), folder: folder, view: view, rowFrame: rowFrame, environment: environment)
            }
            return
        }
        let sample = Array(valid.prefix(5))
        begin(event: event, urls: valid.map { source.url(atRow: $0) }, typeIndices: sample.map { source.entry(atRow: $0).typeIndex },
              view: view, frame: { rowFrame(sample[$0]) }, secondary: secondary)
    }

    /// Any URLs (the sidebar's tree folders): `typeIndices` and `frame(i)` describe the first ≤ 5 of them.
    func begin(event: NSEvent, urls: [URL], typeIndices: [UInt16], view: NSView, frame: (Int) -> NSRect, secondary: Bool) {
        guard !urls.isEmpty, !isDragging else { return }
        pendingURLs = urls
        pendingSecondary = secondary
        isDragging = true
        let sample = Array(typeIndices.prefix(min(5, urls.count)))
        let scale = Double(view.window?.backingScaleFactor ?? 2)
        let composite = DragImageComposer.image(icons: sample.map { icons.typeIcon($0, points: 48, scale: scale) },
                                                count: urls.count, scale: CGFloat(scale))
        let items: [NSDraggingItem] = sample.indices.map { index in
            let item = NSDraggingItem(pasteboardWriter: urls[index] as NSURL)
            let origin = frame(index).origin
            if index == 0 {
                item.setDraggingFrame(NSRect(origin: origin, size: composite.size), contents: composite)
            } else {
                item.setDraggingFrame(NSRect(origin: origin, size: NSSize(width: 1, height: 1)), contents: nil)
            }
            return item
        }
        start(items, view: view, event: event)
    }

    /// Remote rows (spec §4.5): one file promise per item, downloaded only when dropped.
    private func beginRemote(event: NSEvent, rows: [Int], folder: FolderModel, view: NSView, rowFrame: (Int) -> NSRect,
                             environment: CoreEnvironment) {
        guard !isDragging else { return }
        let delegate = RemoteFilePromiseDelegate(environment: environment)
        promiseDelegate = delegate
        pendingRemote = true
        isDragging = true
        let scale = Double(view.window?.backingScaleFactor ?? 2)
        let sample = Array(rows.prefix(5))
        let composite = DragImageComposer.image(icons: sample.map { icons.typeIcon(folder.entry(atRow: $0).typeIndex, points: 48, scale: scale) },
                                                count: rows.count, scale: CGFloat(scale))
        let items: [NSDraggingItem] = rows.enumerated().map { index, row in
            let kind: RemoteItemKind = folder.entry(atRow: row).kind == .directory ? .directory : .file
            let provider = RemoteFilePromiseProvider(
                remoteURL: folder.url(atRow: row),
                fileType: RemoteFilePromiseProvider.fileType(for: RemoteItem(name: folder.name(atRow: row), kind: kind)),
                delegate: delegate)
            let item = NSDraggingItem(pasteboardWriter: provider)
            let origin = index < sample.count ? rowFrame(row).origin : rowFrame(sample[0]).origin
            item.setDraggingFrame(NSRect(origin: origin, size: index == 0 ? composite.size : NSSize(width: 1, height: 1)),
                                  contents: index == 0 ? composite : nil)
            return item
        }
        start(items, view: view, event: event)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        pendingRemote ? [.copy] : [.copy, .move, .link, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        // Remote drags carry their own pasteboard writers (the file promises); file URLs would point at nothing.
        if !pendingRemote { DragPasteboard.write(pendingURLs, secondary: pendingSecondary, to: session.draggingPasteboard) }
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        guard session === self.session else { return }
        endDrag()
        // promiseDelegate stays until the next remote drag: a receiving app (Finder) asks for the promised files
        // after the drop, possibly after the session ended, and NSFilePromiseProvider's delegate is weak.
    }
}
