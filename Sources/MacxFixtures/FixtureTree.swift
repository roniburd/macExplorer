import Darwin
import Foundation

/// Names of the §9 golden tree. Every name is a top-level item of the tree's root directory.
public enum GoldenName {
    public static let plain = "plain.txt"                         // 6 bytes "hello\n"
    public static let empty = "empty.bin"                         // 0 bytes
    public static let sparse = "sparse.bin"                       // 8 MiB logical, 1 byte written at the end
    public static let nfc = "R\u{E9}sum\u{E9}.txt"                // precomposed é
    public static let nfd = "Cafe\u{301}.txt"                     // e + combining acute (APFS preserves NFD)
    public static let emoji = "emoji \u{1F600}\u{1F389}.txt"
    public static let long255 = String(repeating: "n", count: 251) + ".txt"   // 255 UTF-8 bytes
    public static let long255Multibyte = String(repeating: "\u{65E5}", count: 85)  // 85 × 3 bytes = 255
    public static let dotHidden = ".dot-hidden"
    public static let flagHidden = "flag-hidden.txt"              // UF_HIDDEN
    public static let symlinkToFile = "link-to-plain"             // → plain.txt
    public static let symlinkToDir = "link-to-folder"             // → folder
    public static let brokenSymlink = "broken-link"               // → does-not-exist
    public static let alias = "alias-to-plain"                    // Finder alias (bookmark file)
    public static let app = "Tool.app"                            // package (application bundle)
    public static let rtfd = "Note.rtfd"                          // package (document bundle)
    public static let folder = "folder"                           // a.txt, b.txt, sub/
    public static let dottedFolder = "v1.2"                       // directory, not a package
    public static let locked = "locked.txt"                       // UF_IMMUTABLE
    public static let xattrs = "with-xattrs.txt"                  // com.macexplorer.test + com.apple.metadata:kMDItemWhereFroms
    public static let extensionHidden = "ext-hidden.txt"          // Finder kIsExtensionHidden
    public static let hardLinkA = "hardlink-a.txt"                // same inode as hardlink-b.txt
    public static let hardLinkB = "hardlink-b.txt"
    public static let noAccessDir = "no-access-dir"               // mode 000 (contains one file)
    public static let noAccessFile = "no-access.txt"              // mode 000
    public static let executable = "run.sh"                       // mode 755
    public static let readOnly = "read-only.txt"                  // mode 444
    public static let dated = "dated.txt"                         // created 2001-01-01, modified 2002-02-02 (UTC)

    public static let all: [String] = [
        plain, empty, sparse, nfc, nfd, emoji, long255, long255Multibyte, dotHidden, flagHidden,
        symlinkToFile, symlinkToDir, brokenSymlink, alias, app, rtfd, folder, dottedFolder, locked, xattrs,
        extensionHidden, hardLinkA, hardLinkB, noAccessDir, noAccessFile, executable, readOnly, dated,
    ]
}

public enum FixtureTree {
    /// Builds the §9 golden tree at `<sandbox>/<relative>` and returns its URL.
    @discardableResult
    public static func golden(in sandbox: Sandbox, at relative: String = "golden") throws -> URL {
        let root = try sandbox.createDirectory(relative)
        func p(_ name: String) -> String { relative + "/" + name }
        try sandbox.createFile(p(GoldenName.plain), contents: Data("hello\n".utf8))
        try sandbox.createFile(p(GoldenName.empty), contents: Data())
        try sandbox.createSparseFile(p(GoldenName.sparse), size: 8 << 20)
        try sandbox.createFile(p(GoldenName.nfc))
        try sandbox.createFile(p(GoldenName.nfd))
        try sandbox.createFile(p(GoldenName.emoji))
        try sandbox.createFile(p(GoldenName.long255))
        try sandbox.createFile(p(GoldenName.long255Multibyte))
        try sandbox.createFile(p(GoldenName.dotHidden))
        try sandbox.createFile(p(GoldenName.flagHidden))
        try sandbox.setFlags(p(GoldenName.flagHidden), UInt32(UF_HIDDEN))
        try sandbox.createSymlink(p(GoldenName.symlinkToFile), target: GoldenName.plain)
        try sandbox.createSymlink(p(GoldenName.symlinkToDir), target: GoldenName.folder)
        try sandbox.createSymlink(p(GoldenName.brokenSymlink), target: "does-not-exist")
        try sandbox.createFile(p(GoldenName.app + "/Contents/Info.plist"), contents: Data("<plist/>".utf8))
        try sandbox.createFile(p(GoldenName.app + "/Contents/MacOS/Tool"))
        try sandbox.createFile(p(GoldenName.rtfd + "/TXT.rtf"), contents: Data("{\\rtf1}".utf8))
        try sandbox.createFile(p(GoldenName.folder + "/a.txt"))
        try sandbox.createFile(p(GoldenName.folder + "/b.txt"))
        try sandbox.createDirectory(p(GoldenName.folder + "/sub"))
        try sandbox.createFile(p(GoldenName.dottedFolder + "/inside.txt"))
        try sandbox.createAlias(p(GoldenName.alias), to: p(GoldenName.plain))
        try sandbox.createFile(p(GoldenName.locked))
        try sandbox.setFlags(p(GoldenName.locked), UInt32(UF_IMMUTABLE))
        try sandbox.createFile(p(GoldenName.xattrs))
        try sandbox.setXattr(p(GoldenName.xattrs), name: "com.macexplorer.test", value: Data("value".utf8))
        try sandbox.setXattr(p(GoldenName.xattrs), name: "com.apple.metadata:kMDItemWhereFroms",
                             value: try PropertyListSerialization.data(fromPropertyList: ["https://example.com/f"], format: .binary, options: 0))
        try sandbox.createFile(p(GoldenName.extensionHidden))
        try sandbox.setHiddenExtension(p(GoldenName.extensionHidden))
        try sandbox.createFile(p(GoldenName.hardLinkA), contents: Data("linked".utf8))
        try sandbox.createHardLink(p(GoldenName.hardLinkB), to: p(GoldenName.hardLinkA))
        try sandbox.createFile(p(GoldenName.noAccessDir + "/secret.txt"))
        try sandbox.setMode(p(GoldenName.noAccessDir), 0)
        try sandbox.createFile(p(GoldenName.noAccessFile))
        try sandbox.setMode(p(GoldenName.noAccessFile), 0)
        try sandbox.createFile(p(GoldenName.executable), contents: Data("#!/bin/sh\n".utf8))
        try sandbox.setMode(p(GoldenName.executable), 0o755)
        try sandbox.createFile(p(GoldenName.readOnly))
        try sandbox.setMode(p(GoldenName.readOnly), 0o444)
        try sandbox.createFile(p(GoldenName.dated))
        try sandbox.setDates(p(GoldenName.dated), modified: Date(timeIntervalSince1970: 1_012_608_000),
                             created: Date(timeIntervalSince1970: 978_307_200))
        return root
    }

    /// `count` empty files named `<prefix><n zero-padded to width><ext>` (n from 1) in `<sandbox>/<relative>`.
    @discardableResult
    public static func flat(in sandbox: Sandbox, at relative: String, count: Int, prefix: String = "file-",
                            ext: String = ".txt", width: Int = 6, directoriesEvery: Int = 0) throws -> URL {
        precondition(!prefix.contains("/") && !ext.contains("/"), "flat: names must not contain '/'")
        let root = try sandbox.createDirectory(relative)
        let base = root.path(percentEncoded: false)
        guard count > 0 else { return root }
        for i in 1...count {
            let number = String(i)
            let name = prefix + String(repeating: "0", count: max(0, width - number.count)) + number
            if directoriesEvery > 0 && i % directoriesEvery == 0 {
                guard mkdir(base + "/" + name, 0o755) == 0 else { throw Sandbox.posixError(errno, name) }
            } else {
                let fd = open(base + "/" + name + ext, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
                guard fd >= 0 else { throw Sandbox.posixError(errno, name) }
                close(fd)
            }
        }
        return root
    }

    /// A tree `depth` levels deep; each directory has `breadth` subdirectories "d<n>" and `filesPerDir` files "f<n>.txt".
    @discardableResult
    public static func deep(in sandbox: Sandbox, at relative: String, depth: Int, breadth: Int, filesPerDir: Int) throws -> URL {
        let root = try sandbox.createDirectory(relative)
        func fill(_ rel: String, level: Int) throws {
            for f in 0..<filesPerDir { try sandbox.createFile("\(rel)/f\(f).txt") }
            guard level < depth else { return }
            for d in 0..<breadth {
                try sandbox.createDirectory("\(rel)/d\(d)")
                try fill("\(rel)/d\(d)", level: level + 1)
            }
        }
        try fill(relative, level: 1)
        return root
    }
}
