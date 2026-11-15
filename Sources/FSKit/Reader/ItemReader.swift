import CFSKit
import Darwin
import Foundation

public struct ItemReadResult: Sendable {
    public var batch: Batch               // entries for names that exist
    public var missing: [String]          // names that no longer exist (ENOENT / ENOTDIR only)
    public var errors: [String: Int32]    // names that could not be read for another reason (errno); keep their rows

    public init(batch: Batch, missing: [String], errors: [String: Int32]) {
        self.batch = batch
        self.missing = missing
        self.errors = errors
    }
}

public enum ItemReader {
    /// Stats each name in `directory` without following symlinks (watcher incremental path, §4.3).
    /// A directory that no longer exists (ENOENT/ENOTDIR) reports every name missing; any other open
    /// failure (EACCES, EMFILE, EIO, ...) throws, so the caller can fall back to a full re-read.
    /// `context` (lane work) gets a heartbeat per stat, so a long name list on a slow volume is not taken for a stall.
    /// Remote URLs throw ENOTSUP: their decoded path is not a local directory, and an ENOENT there would
    /// otherwise report every name missing.
    /// A name that can't be an entry of `directory` ("", ".", "..", or containing "/" or NUL) is reported missing
    /// without a stat: it would otherwise reach an item elsewhere (a parent, a subfolder's child).
    public static func read(names: [String], in directory: URL, generation: Generation,
                            types: TypeRegistry, context: LaneContext? = nil) throws(ReadFailure) -> ItemReadResult {
        assertOffMain()
        if RemoteScheme.isRemote(directory) { throw ReadFailure(code: ENOTSUP, stage: .open) }
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
        var converter = RecordConverter(types: types, directoryFD: fd)
        var buffer = [UInt8](repeating: 0, count: 2048)
        for name in names {
            context?.heartbeat()
            guard isEntryName(name) else { result.missing.append(name); continue }
            // Stat and convert inside one closure: record.name points into `buffer`, valid only while it is borrowed.
            let code = buffer.withUnsafeMutableBytes { raw -> Int32 in
                var record = cfsk_record()
                guard cfsk_stat_at(fd, name, raw.baseAddress, raw.count, &record) == 0 else { return errno }
                _ = converter.append(record, to: &result.batch, directoriesOnly: false)
                return 0
            }
            if code != 0 {
                if isGone(code) { result.missing.append(name) } else { result.errors[name] = code }
            }
        }
        return result
    }

    static func isGone(_ code: Int32) -> Bool { code == ENOENT || code == ENOTDIR }

    /// A single path component naming an entry: not empty, ".", "..", and without "/" or NUL.
    static func isEntryName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.utf8.contains(0x2F) && !name.utf8.contains(0)
    }
}
