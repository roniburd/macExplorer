import Foundation
import UniformTypeIdentifiers

/// Kind filters shared by every search engine (in-folder filter, crawler, Spotlight).
public enum KindFilter: String, Sendable, Codable, CaseIterable, Hashable {
    case folder, document, text, pdf, image, movie, audio, archive, application, code

    /// Shared by the in-memory matcher (UTType conformance) and Spotlight (kMDItemContentTypeTree).
    public var typeIdentifiers: [String] {
        switch self {
        case .folder: return ["public.folder"]
        case .document: return ["public.text", "com.adobe.pdf", "public.presentation", "public.spreadsheet",
                                "public.rtf", "com.apple.rtfd", "public.composite-content", "org.idpf.epub-container",
                                "org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc"]
        case .text: return ["public.text"]
        case .pdf: return ["com.adobe.pdf"]
        case .image: return ["public.image"]
        case .movie: return ["public.movie"]
        case .audio: return ["public.audio"]
        case .archive: return ["public.archive"]
        case .application: return ["com.apple.application"]
        case .code: return ["public.source-code", "public.script"]
        }
    }
    public var utTypes: [UTType] { typeIdentifiers.compactMap { UTType($0) } }
}

/// Byte-size range: lower inclusive, upper exclusive; nil bounds are open.
public struct ByteRange: Sendable, Codable, Hashable {
    public var lower: Int64?
    public var upper: Int64?
    public init(lower: Int64? = nil, upper: Int64? = nil) { self.lower = lower; self.upper = upper }
    public func contains(_ value: Int64) -> Bool {
        if let lower, value < lower { return false }
        if let upper, value >= upper { return false }
        return true
    }
    public func intersection(_ other: ByteRange) -> ByteRange {
        ByteRange(lower: [lower, other.lower].compactMap { $0 }.max(), upper: [upper, other.upper].compactMap { $0 }.min())
    }
}

/// Time range in ns since 1970 (the `Entry.mtime`/`ctime` unit): lower inclusive, upper exclusive.
public struct TimeRange: Sendable, Codable, Hashable {
    public var lower: Int64?
    public var upper: Int64?
    public init(lower: Int64? = nil, upper: Int64? = nil) { self.lower = lower; self.upper = upper }
    public func contains(_ value: Int64) -> Bool {
        if let lower, value < lower { return false }
        if let upper, value >= upper { return false }
        return true
    }
    public func intersection(_ other: TimeRange) -> TimeRange {
        TimeRange(lower: [lower, other.lower].compactMap { $0 }.max(), upper: [upper, other.upper].compactMap { $0 }.min())
    }
}

/// One name term: a substring, or a whole-name glob when it contains `*` or `?`.
public struct NameTerm: Sendable, Codable, Hashable {
    public var text: String
    public init(_ text: String) { self.text = text }
    public var isGlob: Bool { text.contains("*") || text.contains("?") }
}

/// What a search matches, independent of the engine. Every non-nil part must match (AND).
public struct SearchCriteria: Sendable, Codable, Hashable {
    public var nameTerms: [NameTerm]          // AND
    public var kinds: Set<KindFilter>?        // nil = any; empty set = matches nothing
    public var extensions: Set<String>?       // lowercased, no dot; nil = any; empty = nothing
    public var size: ByteRange?               // files only: directories and packages never match a size filter
    public var modified: TimeRange?
    public var created: TimeRange?
    public init(nameTerms: [NameTerm] = [], kinds: Set<KindFilter>? = nil, extensions: Set<String>? = nil,
                size: ByteRange? = nil, modified: TimeRange? = nil, created: TimeRange? = nil) {
        self.nameTerms = nameTerms; self.kinds = kinds; self.extensions = extensions
        self.size = size; self.modified = modified; self.created = created
    }
    public var isEmpty: Bool {
        nameTerms.isEmpty && kinds == nil && extensions == nil && size == nil && modified == nil && created == nil
    }
}
