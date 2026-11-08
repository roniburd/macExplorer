// Sources/UI/Content/RubberBand.swift
import AppKit

/// Rubber-band selection (§5.5): plain replaces, ⇧ adds, ⌘ toggles.
@MainActor
enum RubberBand {
    enum Mode: Equatable { case replace, add, toggle }

    static func mode(for flags: NSEvent.ModifierFlags) -> Mode {
        flags.contains(.command) ? .toggle : (flags.contains(.shift) ? .add : .replace)
    }

    static func rect(from a: NSPoint, to b: NSPoint) -> NSRect {
        NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    static func hits(in rect: NSRect, layout: FileGridLayout) -> IndexSet {
        var hits = IndexSet()
        for index in layout.indexes(in: rect) where layout.frame(forItem: index).intersects(rect) { hits.insert(index) }
        return hits
    }

    static func selection(base: IndexSet, hits: IndexSet, mode: Mode) -> IndexSet {
        switch mode {
        case .replace: hits
        case .add: base.union(hits)
        case .toggle: base.symmetricDifference(hits)
        }
    }
}

final class RubberBandView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
    }
    required init?(coder: NSCoder) { fatalError("RubberBandView is created in code") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
