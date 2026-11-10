import Foundation

/// Archive formats macExplorer reads (P4-10) or writes (P4-09). Only zip and Apple Archive are created.
public enum ArchiveFormat: String, Sendable, Codable, CaseIterable {
    case zip, appleArchive, tar, tarGzip, tarBzip2, tarXz, gzip

    public var canCreate: Bool { self == .zip || self == .appleArchive }

    /// Longest suffixes first, so "a.tar.gz" is a tar.gz and not a gz.
    static let suffixes: [(String, ArchiveFormat)] = [
        (".tar.gz", .tarGzip), (".tgz", .tarGzip), (".tar.bz2", .tarBzip2), (".tbz2", .tarBzip2), (".tbz", .tarBzip2),
        (".tar.xz", .tarXz), (".txz", .tarXz), (".tar", .tar), (".zip", .zip), (".aar", .appleArchive), (".gz", .gzip),
    ]

    private static func suffix(of name: String) -> (String, ArchiveFormat)? {
        let lower = name.lowercased()
        return suffixes.first { lower.hasSuffix($0.0) && lower.count > $0.0.count }
    }

    /// By name only (no I/O). A bare ".zip" has no name before the suffix and isn't an archive name.
    public static func detect(byName name: String) -> ArchiveFormat? { suffix(of: name)?.1 }

    /// By the first bytes (up to 512); `name` tells a gzipped tar from a plain gzip file.
    public static func detect(magic: Data, name: String) -> ArchiveFormat? {
        let b = [UInt8](magic.prefix(512))
        func starts(_ p: [UInt8]) -> Bool { b.count >= p.count && Array(b[0..<p.count]) == p }
        if starts([0x50, 0x4B, 0x03, 0x04]) || starts([0x50, 0x4B, 0x05, 0x06]) { return .zip }
        // `aa` writes compressed archives as "pbz" + algorithm byte around a YAA/AA01 stream.
        if starts(Array("AA01".utf8)) || starts(Array("YAA1".utf8)) || starts(Array("pbz".utf8)) { return .appleArchive }
        if starts([0x1F, 0x8B]) { return detect(byName: name) == .gzip ? .gzip : .tarGzip }
        if starts(Array("BZh".utf8)) { return .tarBzip2 }
        if starts([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return .tarXz }
        if b.count >= 262, Array(b[257..<262]) == Array("ustar".utf8) { return .tar }
        return nil
    }

    /// The name without its archive suffix ("photos.tar.gz" → "photos"); other names are returned unchanged.
    public static func baseName(stripping name: String) -> String {
        guard let s = suffix(of: name) else { return name }
        return String(name.dropLast(s.0.count))
    }

    /// The extension of a created archive (creatable formats only).
    var fileExtension: String {
        switch self {
        case .zip: "zip"
        case .appleArchive: "aar"
        case .tar: "tar"
        case .tarGzip: "tar.gz"
        case .tarBzip2: "tar.bz2"
        case .tarXz: "tar.xz"
        case .gzip: "gz"
        }
    }
}

enum ArchiveNaming {
    /// Finder's names: one item keeps its whole name ("a.txt" → "a.txt.zip"), several make "Archive.zip".
    static func outputName(for sources: [URL], format: ArchiveFormat) -> String {
        sources.count == 1 ? "\(sources[0].lastPathComponent).\(format.fileExtension)" : "Archive.\(format.fileExtension)"
    }
}
