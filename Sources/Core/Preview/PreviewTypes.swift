import Foundation
import MacxFS

public struct PreviewSubject: Sendable, Equatable {
    public var url: URL
    public var kind: Kind
    public var typeIndex: UInt16
    public var flags: EntryFlags
    public var size: Int64
    public init(url: URL, kind: Kind, typeIndex: UInt16, flags: EntryFlags, size: Int64) {
        self.url = url; self.kind = kind; self.typeIndex = typeIndex; self.flags = flags; self.size = size
    }
}

public enum PreviewContent: Sendable, Equatable {
    case nothingSelected, multiple(count: Int, bytes: Int64)
    case folder(URL), text(URL), quickLook(URL)
    case cloudPlaceholder(URL), brokenLink(URL), unavailable(URL, code: Int32)
}

public enum PreviewClass: Sendable, Equatable { case text, quickLook, sniff }
