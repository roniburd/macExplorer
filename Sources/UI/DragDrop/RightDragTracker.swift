// Sources/UI/DragDrop/RightDragTracker.swift
import AppKit

/// §5.6 right-drag: rightMouseDown only records the point. Moving more than ~3 pt before rightMouseUp starts a
/// drag (no menu); otherwise rightMouseUp shows the context menu at the original point. Window coordinates.
struct RightDragTracker: Equatable {
    enum Outcome: Equatable { case none, beginDrag, showMenu(at: NSPoint) }
    static let threshold: CGFloat = 3
    private(set) var downPoint: NSPoint?
    private(set) var dragging = false

    static func exceedsThreshold(from a: NSPoint, to b: NSPoint) -> Bool {
        hypot(b.x - a.x, b.y - a.y) > threshold
    }

    mutating func rightMouseDown(at point: NSPoint) {
        downPoint = point
        dragging = false
    }

    mutating func rightMouseDragged(to point: NSPoint) -> Outcome {
        guard let downPoint, !dragging, Self.exceedsThreshold(from: downPoint, to: point) else { return .none }
        dragging = true
        return .beginDrag
    }

    mutating func rightMouseUp(at point: NSPoint) -> Outcome {
        defer { downPoint = nil; dragging = false }
        guard let downPoint, !dragging else { return .none }
        return .showMenu(at: downPoint)
    }
}
