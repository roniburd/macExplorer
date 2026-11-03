import Foundation
import Synchronization

public enum SortKeys {
    static let foldOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
    static let foldLocale = Locale(identifier: "en_US_POSIX")

    /// [kind byte: 0 folder / 1 other] + CFStringFold(case|diacritic|width, fixed en_US_POSIX locale) UTF-8 with
    /// digit runs encoded as [len byte][digits without leading zeros] (tie-break on original run length)
    /// + 0x00 + unfolded NFC bytes.
    public static func nameKey(_ name: String, isFolder: Bool) -> [UInt8] {
        let folded = name.folding(options: foldOptions, locale: foldLocale)
        var key: [UInt8] = [isFolder ? 0 : 1]
        key.reserveCapacity(folded.utf8.count * 2 + 4)
        var digits: [UInt8] = []
        func flushDigits() {
            guard !digits.isEmpty else { return }
            var start = 0
            while start < digits.count - 1 && digits[start] == UInt8(ascii: "0") { start += 1 }  // keep ≥ 1 digit
            let run = digits[start...].prefix(255)
            key.append(UInt8(run.count))
            key.append(contentsOf: run)
            digits.removeAll(keepingCapacity: true)
        }
        for byte in folded.utf8 {
            if byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") {
                digits.append(byte)
            } else {
                flushDigits()
                key.append(byte)
            }
        }
        flushDigits()
        key.append(0)
        // Tie-break: unfolded NFC bytes. For equal digit values the run with more leading zeros sorts first.
        key.append(contentsOf: name.precomposedStringWithCanonicalMapping.utf8)
        return key
    }

    /// Same fold, no digit encoding, no kind prefix.
    public static func searchFold(_ text: String) -> [UInt8] {
        Array(text.folding(options: foldOptions, locale: foldLocale).utf8)
    }

    /// Name keys for storage indices `range` of `store`, using concurrentPerform.
    public static func nameKeys(_ store: EntryStore, range: Range<Int>) -> SortKeyColumn {
        build(count: range.count) { i in
            let index = UInt32(range.lowerBound + i)
            return nameKey(store.name(index), isFolder: store.entry(index).isFolderForSorting)
        }
    }

    public static func nameKeys(_ batch: Batch) -> SortKeyColumn {
        build(count: batch.count) { i in nameKey(batch.name(at: i), isFolder: batch.entries[i].isFolderForSorting) }
    }

    /// Extension sort key: searchFold of the extension after the last "." (none for folders, ".bashrc", "name.").
    /// Build incrementally next to nameKeys so extension sorts never re-fold the whole store per batch.
    public static func extensionKey(_ name: String, kind: Kind) -> [UInt8] {
        guard kind != .directory else { return [] }
        var name = name
        return name.withUTF8 { bytes in
            fileExtensionRange(bytes).map { searchFold(String(decoding: UnsafeBufferPointer(rebasing: bytes[$0]), as: UTF8.self)) } ?? []
        }
    }

    public static func extensionKeys(_ store: EntryStore, range: Range<Int>) -> SortKeyColumn {
        build(count: range.count) { i in
            let index = UInt32(range.lowerBound + i)
            return extensionKey(store.name(index), kind: store.entry(index).kind)
        }
    }

    public static func extensionKeys(_ batch: Batch) -> SortKeyColumn {
        build(count: batch.count) { i in extensionKey(batch.name(at: i), kind: batch.entries[i].kind) }
    }

    public static func searchKeys(_ store: EntryStore) -> SortKeyColumn {
        build(count: store.count) { i in searchFold(store.name(UInt32(i))) }
    }

    /// Parallel build in chunks of 1,024; chunks are concatenated in order.
    private static func build(count: Int, _ make: @Sendable (Int) -> [UInt8]) -> SortKeyColumn {
        let chunk = 1_024
        let chunks = (count + chunk - 1) / chunk
        guard chunks > 1 else {
            var column = SortKeyColumn()
            for i in 0..<count { column.append(make(i)) }
            return column
        }
        // One locked write per 1,024-key chunk: negligible contention, no unsafe sharing.
        let parts = Mutex([SortKeyColumn](repeating: SortKeyColumn(), count: chunks))
        DispatchQueue.concurrentPerform(iterations: chunks) { c in
            var column = SortKeyColumn()
            for i in (c * chunk)..<min(count, (c + 1) * chunk) { column.append(make(i)) }
            parts.withLock { $0[c] = column }
        }
        var result = SortKeyColumn()
        for part in parts.withLock({ $0 }) { result.append(contentsOf: part) }
        return result
    }
}
