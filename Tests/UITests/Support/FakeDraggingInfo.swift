import AppKit

/// A drag carrying file URLs on a private, uniquely named pasteboard (never the general or drag pasteboard), so a
/// drop target's `draggingEntered` / `performDragOperation` can run headless. Call `release()` when done.
@MainActor
final class FakeDraggingInfo: NSObject, @MainActor NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingSourceOperationMask: NSDragOperation

    init(fileURLs: [URL], sourceMask: NSDragOperation = [.copy, .move, .link, .generic]) {
        draggingPasteboard = NSPasteboard(name: NSPasteboard.Name("macx-tests-drag-\(UUID().uuidString)"))
        draggingPasteboard.clearContents()
        draggingPasteboard.writeObjects(fileURLs as [NSURL])
        draggingSourceOperationMask = sourceMask
    }

    func release() { draggingPasteboard.releaseGlobally() }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
