import Foundation
import AppleArchive
import System
import MacxFS

public enum ArchiveListError: Error, Sendable, Equatable { case unlistable }

/// Lists an archive's entries without writing anything (P4-10), so `ArchiveSafety` can refuse it first. Lane only.
///
/// zip and the tar family: `/usr/bin/tar -tf` (paths) and `-tvf` (types and link targets) in the same order.
/// Apple Archive: the `ArchiveStream` headers (`PAT`, `TYP`, `LNK`). gzip: one file named after the archive.
/// The lister always runs the real `/usr/bin/tar` (never `FileOpTuning.toolOverride`): it is the safety check. zip and
/// the tar family are extracted by that same bsdtar (`ExtractJob`), so exactly the listed entries are written; a zip's
/// local entries that its central directory doesn't list are neither listed nor extracted.
enum ArchiveLister {
    static func entries(of url: URL, format: ArchiveFormat, context: LaneContext) throws -> [ArchiveEntry] {
        assertOffMain()
        switch format {
        case .zip, .tar, .tarGzip, .tarBzip2, .tarXz: return try tarEntries(url, context: context)
        case .appleArchive: return try appleArchiveEntries(url, context: context)
        case .gzip: return [ArchiveEntry(path: ArchiveFormat.baseName(stripping: url.lastPathComponent), type: .file)]
        }
    }

    // MARK: bsdtar

    private static func tarEntries(_ url: URL, context: LaneContext) throws -> [ArchiveEntry] {
        func list(_ flags: String) throws -> [String] {
            let r = try ProcessRunner.run("/usr/bin/tar", [flags, url.path], output: .capture, context: context,
                                          isPaused: { false }, onStderrLine: { _ in })
            guard r.status == 0, r.stdout.count < ProcessRunner.captureLimit else { throw ArchiveListError.unlistable }
            var lines = String(decoding: r.stdout, as: UTF8.self).components(separatedBy: "\n")
            if lines.last == "" { lines.removeLast() }
            return lines
        }
        let paths = try list("-tf")
        let verbose = try list("-tvf")
        guard paths.count == verbose.count else { throw ArchiveListError.unlistable }
        var out: [ArchiveEntry] = []
        out.reserveCapacity(paths.count)
        for (i, (path, line)) in zip(paths, verbose).enumerated() {
            if i & 255 == 0 { context.heartbeat() }
            guard let entry = entry(path: path, verboseLine: line) else { throw ArchiveListError.unlistable }
            out.append(entry)
        }
        return out
    }

    /// One `tar -tv` line for the entry `path` (from `tar -t`): the mode string's first character gives the type
    /// ("d", "l" with " -> target", "h" with " link to target", "-" file, anything else other). nil when the line
    /// doesn't end with that path (the two listings disagree).
    static func entry(path: String, verboseLine line: String) -> ArchiveEntry? {
        guard let kind = line.first else { return nil }
        func target(after separator: String) -> String? {
            // The first " <path><separator>": the mode/owner/date columns before the path never contain the separator.
            guard let r = line.range(of: " " + path + separator) else { return nil }
            return String(line[r.upperBound...])
        }
        switch kind {
        case "l": return target(after: " -> ").map { ArchiveEntry(path: path, type: .symlink(target: $0)) }
        case "h": return target(after: " link to ").map { ArchiveEntry(path: path, type: .hardlink(target: $0)) }
        default:
            guard line.hasSuffix(" " + path) else { return nil }
            switch kind {
            case "d": return ArchiveEntry(path: path, type: .directory)
            case "-": return ArchiveEntry(path: path, type: .file)
            default: return ArchiveEntry(path: path, type: .other)
            }
        }
    }

    // MARK: Apple Archive

    private static func appleArchiveEntries(_ url: URL, context: LaneContext) throws -> [ArchiveEntry] {
        guard let file = ArchiveByteStream.fileStream(path: FilePath(url.path), mode: .readOnly, options: [],
                                                      permissions: FilePermissions(rawValue: 0o644)) else {
            throw ArchiveListError.unlistable
        }
        defer { try? file.close() }
        guard let decompressed = ArchiveByteStream.decompressionStream(readingFrom: file) else { throw ArchiveListError.unlistable }
        defer { try? decompressed.close() }
        guard let decoder = ArchiveStream.decodeStream(readingFrom: decompressed) else { throw ArchiveListError.unlistable }
        defer { try? decoder.close() }
        let pat = ArchiveHeader.FieldKey("PAT"), lnk = ArchiveHeader.FieldKey("LNK")
        var out: [ArchiveEntry] = []
        var count = 0
        do {
            // readHeader skips the previous entry's data blobs.
            while let header = try decoder.readHeader() {
                count += 1
                if count & 255 == 0 { context.heartbeat() }
                if context.isCancelled { throw LaneError.cancelled }
                guard case .string(_, let path)? = header.field(forKey: pat) else { throw ArchiveListError.unlistable }
                let type: ArchiveEntry.EntryType
                switch header.entryType {
                case .regularFile?: type = .file
                case .directory?: type = .directory
                case .link?:
                    guard case .string(_, let target)? = header.field(forKey: lnk) else { throw ArchiveListError.unlistable }
                    type = .symlink(target: target)
                default: type = .other
                }
                if path.isEmpty, type == .directory { continue }          // aa's entry for the archived folder itself
                out.append(ArchiveEntry(path: path, type: type))
            }
        } catch let error as LaneError {
            throw error
        } catch {
            throw ArchiveListError.unlistable
        }
        return out
    }
}
