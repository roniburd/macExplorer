import Darwin
import Foundation
import Synchronization

public enum DiskImageFormat: String, Sendable, CaseIterable {
    case apfs = "APFS"
    case hfsPlus = "HFS+"
    case exfat = "ExFAT"
    case msdos = "MS-DOS"      // FAT16/FAT32 chosen by hdiutil from the size
}

public enum DiskImageError: Error, Sendable, Equatable {
    case hdiutilFailed(arguments: [String], status: Int32, output: String)
    case timedOut(arguments: [String])
}

/// A disk image created inside a Sandbox and attached with `-nobrowse` at `<sandbox>/mnt-<id>`.
/// Detach is idempotent; Sandbox.destroy() force-detaches anything still attached.
public final class DiskImage: Sendable {
    public let imageURL: URL
    public let mountPoint: URL
    /// Mount point relative to the sandbox root, for Sandbox write helpers ("mnt-1a2b3c4d").
    public let relativeMountPath: String
    public let format: DiskImageFormat
    public let isReadOnly: Bool
    private let sandbox: Sandbox
    private let attached = Mutex<Bool>(false)

    public static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: "/usr/bin/hdiutil") }

    /// Creates `<sandbox>/img-<id>.dmg` (UDIF, GPT), attaches it read-write, runs `populate` with the mount
    /// point, and — if `readOnly` — detaches and re-attaches it with `-readonly`.
    public static func create(in sandbox: Sandbox, format: DiskImageFormat, sizeMB: Int = 32,
                              volumeName: String = "MACXTEST", readOnly: Bool = false,
                              populate: ((URL) throws -> Void)? = nil) throws -> DiskImage {
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let image = sandbox.url("img-\(id).dmg")
        let mount = try sandbox.createDirectory("mnt-\(id)")
        try hdiutil(["create", "-size", "\(sizeMB)m", "-fs", format.rawValue, "-volname", volumeName,
                     "-type", "UDIF", "-layout", "GPTSPUD", image.path(percentEncoded: false)])
        let disk = DiskImage(sandbox: sandbox, image: image, mount: mount, relative: "mnt-\(id)",
                             format: format, readOnly: readOnly)
        try disk.attach(readOnly: false)
        if let populate { try populate(mount) }
        if readOnly {
            try disk.detach()
            try disk.attach(readOnly: true)
        }
        return disk
    }

    private init(sandbox: Sandbox, image: URL, mount: URL, relative: String, format: DiskImageFormat, readOnly: Bool) {
        self.sandbox = sandbox
        self.imageURL = image
        self.mountPoint = mount
        self.relativeMountPath = relative
        self.format = format
        self.isReadOnly = readOnly
    }

    private func attach(readOnly: Bool) throws {
        var args = ["attach", "-nobrowse", "-noautoopen", "-noverify", "-mountpoint", mountPoint.path(percentEncoded: false)]
        if format == .apfs || format == .hfsPlus { args += ["-owners", "on"] }
        if readOnly { args.append("-readonly") }
        args.append(imageURL.path(percentEncoded: false))
        try DiskImage.hdiutil(args)
        attached.withLock { $0 = true }
        sandbox.registerMount(mountPoint.path(percentEncoded: false))
    }

    /// `hdiutil detach -force`. Idempotent.
    public func detach() throws {
        let wasAttached = attached.withLock { value -> Bool in
            defer { value = false }
            return value
        }
        guard wasAttached else { return }
        sandbox.unregisterMount(mountPoint.path(percentEncoded: false))
        try DiskImage.hdiutil(["detach", "-force", mountPoint.path(percentEncoded: false)])
    }

    static func forceDetach(mountPoint: String) {
        _ = try? hdiutil(["detach", "-force", mountPoint])
    }

    @discardableResult
    static func hdiutil(_ arguments: [String], timeout: Duration = .seconds(60)) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/hdiutil")
        process.arguments = arguments + ["-quiet"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        let seconds = Double(timeout.components.seconds)
        if done.wait(timeout: .now() + seconds) == .timedOut {
            process.terminate()
            throw DiskImageError.timedOut(arguments: arguments)
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw DiskImageError.hdiutilFailed(arguments: arguments, status: process.terminationStatus, output: output)
        }
        return output
    }
}
