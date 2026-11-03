import CFSKit
import Darwin
import Foundation

public struct ItemReadResult: Sendable {
    public var batch: Batch          // entries for names that exist
    public var missing: [String]     // names that no longer exist
}

public enum ItemReader {
    /// Stats each name in `directory` without following symlinks (watcher incremental path, §4.3).
    public static func read(names: [String], in directory: URL, generation: Generation, types: TypeRegistry) -> ItemReadResult {
        assertOffMain()
        var result = ItemReadResult(batch: Batch(generation: generation), missing: [])
        guard let fd = try? openDirectory(directory) else {
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
                result.missing.append(name)   // ENOENT (and anything else unreadable): treat as gone
                continue
            }
            _ = buffer.withUnsafeBytes { _ in converter.append(record, to: &result.batch, directoriesOnly: false) }
        }
        return result
    }
}
