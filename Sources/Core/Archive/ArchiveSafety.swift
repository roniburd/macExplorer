import Foundation

/// One entry of an archive as its lister reports it (P4-10). `path` is exactly what the archive stores.
public struct ArchiveEntry: Sendable, Equatable {
    public enum EntryType: Sendable, Equatable {
        case file, directory, symlink(target: String)
        /// A tar hard link: `target` is another entry's path inside the archive.
        case hardlink(target: String)
        case other
    }
    public var path: String
    public var type: EntryType
    public init(path: String, type: EntryType) { self.path = path; self.type = type }
}

public enum ArchiveSafetyProblem: Sendable, Equatable { case absolutePath(String), parentTraversal(String), throughSymlink(String), unlistable }

/// The rules every entry passes before Extract writes anything (P4-10):
/// 1. `absolutePath`: the path starts with "/" (after one leading "./").
/// 2. `parentTraversal`: a ".." component, or a link whose target leaves the archive root (symlink targets resolve
///    from the link's folder, hard-link targets from the root; absolute targets always leave).
/// 3. `throughSymlink`: a path (or hard-link target) below an earlier symlink entry ("link" then "link/evil.txt").
/// 4. `unlistable`: an empty path or one containing NUL (and, in the job, a listing that failed).
///
/// Paths split on "/" and also on "\" (zips made on Windows; some extractors treat it as a separator), dropping empty
/// and "." components. Symlink prefixes compare case-insensitively, as on the default APFS volume. Being stricter than
/// the tools only refuses odd archives; being laxer could write outside the destination.
public enum ArchiveSafety {
    static func components(_ p: String) -> [Substring] {
        p.split(whereSeparator: { $0 == "/" || $0 == "\\" }).filter { $0 != "." }
    }

    public static func problems(_ entries: [ArchiveEntry]) -> [ArchiveSafetyProblem] {
        var t = Tracker()
        return entries.compactMap { t.check($0) }
    }

    /// Checks entries in archive order, remembering symlink entries for rule 3.
    public struct Tracker: Sendable {
        private var links: Set<[String]> = []
        public init() {}

        public mutating func check(_ entry: ArchiveEntry) -> ArchiveSafetyProblem? {
            var path = entry.path
            if path.isEmpty || path.contains("\0") { return .unlistable }
            if path.hasPrefix("./") { path.removeFirst(2) }
            if path.hasPrefix("/") || path.hasPrefix("\\") { return .absolutePath(entry.path) }
            let parts = ArchiveSafety.components(path)
            if parts.contains("..") { return .parentTraversal(entry.path) }
            if parts.isEmpty {
                // The archive root itself ("./", "."): harmless as a folder, meaningless as anything else.
                return entry.type == .directory ? nil : .unlistable
            }
            if throughLink(parts) { return .throughSymlink(entry.path) }
            switch entry.type {
            case .symlink(let target):
                links.insert(Self.key(parts))
                if target.isEmpty || target.contains("\0") { return .unlistable }
                if target.hasPrefix("/") || target.hasPrefix("\\") { return .parentTraversal(entry.path) }
                var depth = parts.count - 1                          // the link's folder depth
                for c in ArchiveSafety.components(target) {
                    if c == ".." { depth -= 1; if depth < 0 { return .parentTraversal(entry.path) } } else { depth += 1 }
                }
            case .hardlink(let target):
                if target.isEmpty || target.contains("\0") { return .unlistable }
                var t = target
                if t.hasPrefix("./") { t.removeFirst(2) }
                if t.hasPrefix("/") || t.hasPrefix("\\") { return .parentTraversal(entry.path) }
                let targetParts = ArchiveSafety.components(t)
                if targetParts.isEmpty || targetParts.contains("..") { return .parentTraversal(entry.path) }
                if throughLink(targetParts) { return .throughSymlink(entry.path) }
            case .file, .directory, .other:
                break
            }
            return nil
        }

        /// Whether a proper prefix of `parts` is an earlier symlink entry.
        private func throughLink(_ parts: [Substring]) -> Bool {
            guard !links.isEmpty, parts.count > 1 else { return false }
            let key = Self.key(parts)
            return (1..<key.count).contains { links.contains(Array(key.prefix($0))) }
        }

        private static func key(_ parts: [Substring]) -> [String] { parts.map { $0.lowercased() } }
    }
}
