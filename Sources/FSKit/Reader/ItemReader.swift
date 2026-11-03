import CFSKit
import Darwin
import Foundation

public struct ItemReadResult: Sendable {
    public var batch: Batch               // entries for names that exist
    public var missing: [String]          // names that no longer exist (ENOENT / ENOTDIR only)
    public var errors: [String: Int32]    // names that could not be read for another reason (errno); keep their rows
}

public enum ItemReader {
    /// Stats each name in `directory` without following symlinks (watcher incremental path, §4.3).
    /// A directory that no longer exists (ENOENT/ENOTDIR) reports every name missing; any other open
    /// failure (EACCES, EMFILE, EIO, ...) throws, so the caller can fall back to a full re-read.
    public static func read(names: [String], in directory: URL, generation: Generation,
                            types: TypeRegistry) throws(ReadFailure) -> ItemReadResult {
        assertOffMain()
        var result = ItemReadResult(batch: Batch(generation: generation), missing: [], errors: [:])
        let fd: Int32
        do {
            fd = try openDirectory(directory)
        } catch {
            guard isGone(error.code) else { throw error }
            result.missing = names
            return result
        }
        defer { close(fd) }
        var converter = RecordConverter(types: types)
        var buffer = [UInt8](repeating: 0, count: 2048)
        for name in names {
            var record = cfsk_record()
            let rc = buffer.withUnsafeMutableBytes { cfsk_stat_at(fd, name, $0.baseAddress, $0.count, &record) }
            if rc != 0 {
                let code = errno
                if isGone(code) { result.missing.append(name) } else { result.errors[name] = code }
                continue
            }
            _ = buffer.withUnsafeBytes { _ in converter.append(record, to: &result.batch, directoriesOnly: false) }
        }
        return result
    }

    static func isGone(_ code: Int32) -> Bool { code == ENOENT || code == ENOTDIR }
}
