import AppKit
import UniformTypeIdentifiers

/// Word and OpenDocument files as attributed text (AppKit's readers, the ones TextEdit uses), adjusted for the
/// preview pane: text that was black or unset follows the system text colour (readable in Dark Mode), and white page
/// backgrounds are dropped. Layout the text system doesn't model (columns, text boxes, headers/footers) is lost.
enum DocumentReflow {
    static func documentType(for type: UTType) -> NSAttributedString.DocumentType? {
        if type.identifier == "com.microsoft.word.doc" { return .docFormat }
        if type.identifier == "org.oasis-open.opendocument.text" { return .openDocument }
        if type.identifier.hasPrefix("org.openxmlformats.wordprocessingml") { return .officeOpenXML }
        return nil
    }

    /// Hands the converted text from the detached task to the caller. The string is built inside the task and
    /// never touched there again, so ownership moves with the box (the one concurrency escape in this file).
    private final class Handoff: @unchecked Sendable {
        let text: NSAttributedString
        init(_ text: NSAttributedString) { self.text = text }
    }

    /// Converts off the main thread; nil when AppKit can't read it.
    static func convert(_ data: Data, type: UTType) async -> NSAttributedString? {
        guard let documentType = documentType(for: type) else { return nil }
        let box = await Task.detached(priority: .userInitiated) { () -> Handoff? in
            guard let read = try? NSAttributedString(data: data, options: [.documentType: documentType], documentAttributes: nil)
            else { return nil }
            return Handoff(adapted(read))
        }.value
        return box?.text
    }

    static func adapted(_ text: NSAttributedString) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: text)
        let all = NSRange(location: 0, length: out.length)
        out.enumerateAttribute(.foregroundColor, in: all) { value, range, _ in
            if let color = value as? NSColor, !isNeutralDark(color) { return }
            out.addAttribute(.foregroundColor, value: NSColor.textColor, range: range)
        }
        out.enumerateAttribute(.backgroundColor, in: all) { value, range, _ in
            if let color = value as? NSColor, isNeutralLight(color) { out.removeAttribute(.backgroundColor, range: range) }
        }
        out.enumerateAttribute(.font, in: all) { value, range, _ in
            if value == nil { out.addAttribute(.font, value: NSFont.systemFont(ofSize: 12), range: range) }
        }
        return out
    }

    private static func components(_ color: NSColor) -> (brightness: CGFloat, saturation: CGFloat)? {
        guard let c = color.usingColorSpace(.sRGB) else { return nil }
        return (c.brightnessComponent, c.saturationComponent)
    }

    /// Black and dark grays: the document's "automatic" text colour.
    static func isNeutralDark(_ color: NSColor) -> Bool {
        guard let c = components(color) else { return false }
        return c.brightness < 0.35 && c.saturation < 0.25
    }

    static func isNeutralLight(_ color: NSColor) -> Bool {
        guard let c = components(color) else { return false }
        return c.brightness > 0.92 && c.saturation < 0.1
    }
}
