import Darwin
import Foundation

public enum PermissionAccess: String, Sendable, CaseIterable { case readWrite, readOnly, writeOnly, noAccess }
public enum PermissionClass: Sendable, CaseIterable { case owner, group, everyone }

/// The §5.8 permission popups mapped onto POSIX mode bits. Only the read and write bits of one class change;
/// execute, setuid/setgid/sticky and the other classes are kept.
public enum PermissionModel {
    public static func access(_ mode: UInt16, _ who: PermissionClass) -> PermissionAccess {
        let bits = (mode >> shift(who)) & 0o6
        switch bits {
        case 0o6: return .readWrite
        case 0o4: return .readOnly
        case 0o2: return .writeOnly
        default: return .noAccess
        }
    }

    public static func applying(_ access: PermissionAccess, _ who: PermissionClass, to mode: UInt16) -> UInt16 {
        let bits: UInt16 = switch access {
        case .readWrite: 0o6
        case .readOnly: 0o4
        case .writeOnly: 0o2
        case .noAccess: 0
        }
        let s = shift(who)
        return (mode & ~(UInt16(0o6) << s)) | (bits << s)
    }

    /// "Executable" for files: any execute bit is set.
    public static func isExecutable(_ mode: UInt16) -> Bool { mode & 0o111 != 0 }

    /// `getpwuid_r` name, or the number when the id is unknown. Thread-safe.
    public static func userName(_ uid: UInt32) -> String {
        withBuffer(sysconf(_SC_GETPW_R_SIZE_MAX)) { buffer, size in
            var pwd = passwd()
            var result: UnsafeMutablePointer<passwd>?
            guard getpwuid_r(uid, &pwd, buffer, size, &result) == 0, result != nil, let name = pwd.pw_name else { return nil }
            return String(cString: name)
        } ?? String(uid)
    }

    /// `getgrgid_r` name, or the number when the id is unknown. Thread-safe.
    public static func groupName(_ gid: UInt32) -> String {
        withBuffer(sysconf(_SC_GETGR_R_SIZE_MAX)) { buffer, size in
            var grp = group()
            var result: UnsafeMutablePointer<group>?
            guard getgrgid_r(gid, &grp, buffer, size, &result) == 0, result != nil, let name = grp.gr_name else { return nil }
            return String(cString: name)
        } ?? String(gid)
    }

    private static func shift(_ who: PermissionClass) -> UInt16 {
        switch who {
        case .owner: 6
        case .group: 3
        case .everyone: 0
        }
    }

    private static func withBuffer(_ suggested: Int, _ body: (UnsafeMutablePointer<CChar>, Int) -> String?) -> String? {
        let size = suggested > 0 ? max(suggested, 1024) : 16_384
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: size)
        defer { buffer.deallocate() }
        return body(buffer, size)
    }
}
