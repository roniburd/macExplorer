import Darwin
import Foundation
import Synchronization

/// uid → user name, looked up once per uid. Unknown uids show as their number.
public final class OwnerNameCache: Sendable {
    private let names = Mutex<[UInt32: String]>([:])

    public init() {}

    /// Directory-services lookup on first use per uid: call from lane work (ExtendedAttributeReader does).
    public func name(for uid: UInt32) -> String {
        if let n = names.withLock({ $0[uid] }) { return n }
        let name = Self.lookup(uid) ?? String(uid)
        names.withLock { $0[uid] = name }
        return name
    }

    private static func lookup(_ uid: UInt32) -> String? {
        var size = max(1_024, sysconf(Int32(_SC_GETPW_R_SIZE_MAX)))
        while size <= 1 << 20 {
            var pwd = passwd()
            var result: UnsafeMutablePointer<passwd>?
            var buffer = [CChar](repeating: 0, count: size)
            let rc = getpwuid_r(uid_t(uid), &pwd, &buffer, buffer.count, &result)
            if rc == ERANGE { size *= 2; continue }
            guard rc == 0, result != nil, let raw = pwd.pw_name else { return nil }
            return String(cString: raw)
        }
        return nil
    }
}
