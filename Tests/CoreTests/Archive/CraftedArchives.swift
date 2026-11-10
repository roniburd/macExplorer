import Foundation

/// Writes minimal archives byte by byte so tests can build entries no real tool would produce.
enum CraftedArchives {
    struct TarEntry { var path: String; var type: UInt8 = 0x30; var linkTarget = ""; var contents = Data() }   // '0' file, '2' symlink, '5' dir

    static func tar(_ entries: [TarEntry]) -> Data {
        var out = Data()
        for e in entries {
            var h = [UInt8](repeating: 0, count: 512)
            func put(_ s: String, _ offset: Int, _ len: Int) { for (i, b) in s.utf8.prefix(len).enumerated() { h[offset + i] = b } }
            func octal(_ v: Int, _ offset: Int, _ len: Int) { put(String(String(v, radix: 8).suffix(len - 1)).leftPad(len - 1), offset, len - 1) }
            put(e.path, 0, 100); octal(e.type == 0x35 ? 0o755 : 0o644, 100, 8); octal(0, 108, 8); octal(0, 116, 8)
            octal(e.contents.count, 124, 12); octal(1_700_000_000, 136, 12)
            for i in 148..<156 { h[i] = 0x20 }
            h[156] = e.type; put(e.linkTarget, 157, 100); put("ustar", 257, 6); put("00", 263, 2)
            let sum = h.reduce(0) { $0 + Int($1) }
            put(String(String(sum, radix: 8)).leftPad(6) + "\0 ", 148, 8)
            out.append(contentsOf: h)
            out.append(e.contents)
            let pad = (512 - e.contents.count % 512) % 512
            out.append(Data(count: pad))
        }
        out.append(Data(count: 1024))
        return out
    }

    /// Stored (uncompressed) zip; symlinks use Unix mode 0o120777 in the external attributes. An entry with
    /// `inCentralDirectory: false` is written as a local entry only (the central directory never mentions it).
    struct ZipEntry { var path: String; var contents = Data(); var symlink = false; var inCentralDirectory = true }
    static func zip(_ entries: [ZipEntry]) -> Data {
        var out = Data(), central = Data()
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
        for e in entries {
            let name = Array(e.path.utf8)
            let crc = crc32(e.contents)
            let offset = UInt32(out.count)
            out.append(contentsOf: [0x50, 0x4B, 0x03, 0x04] + le16(10) + le16(0) + le16(0) + le16(0) + le16(0) + le32(crc)
                       + le32(UInt32(e.contents.count)) + le32(UInt32(e.contents.count)) + le16(name.count) + le16(0) + name)
            out.append(e.contents)
            let mode: UInt32 = e.symlink ? 0o120777 : 0o100644
            guard e.inCentralDirectory else { continue }
            central.append(contentsOf: [0x50, 0x4B, 0x01, 0x02] + le16(0x031E) + le16(10) + le16(0) + le16(0) + le16(0) + le16(0)
                           + le32(crc) + le32(UInt32(e.contents.count)) + le32(UInt32(e.contents.count)) + le16(name.count)
                           + le16(0) + le16(0) + le16(0) + le16(0) + le32(mode << 16) + le32(offset) + name)
        }
        let cdOffset = UInt32(out.count)
        let listed = entries.filter(\.inCentralDirectory).count
        out.append(central)
        out.append(contentsOf: [0x50, 0x4B, 0x05, 0x06] + le16(0) + le16(0) + le16(listed) + le16(listed)
                   + le32(UInt32(central.count)) + le32(cdOffset) + le16(0))
        return out
    }
}

private extension String { func leftPad(_ n: Int) -> String { String(repeating: "0", count: max(0, n - count)) + self } }

/// CRC-32 (IEEE 802.3, reflected, polynomial 0xEDB88320), bitwise; test archives are tiny.
private func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
    }
    return ~crc
}
