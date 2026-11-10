import Foundation
import Darwin
import Darwin.membership
import MacxFS

/// Users and groups by name or UUID, through the membership API (`mbr_*`) and the passwd/group databases.
/// Every lookup may block on Directory Services, so call them on a lane.
public enum PrincipalDirectory {
    public static let everyone = ACLPrincipal.group(name: "everyone", uuid: UUID(uuidString: "ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C")!)

    private static func uuid(_ fill: (UnsafeMutablePointer<UInt8>) -> Int32) -> UUID? {
        var raw: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        let rc = withUnsafeMutableBytes(of: &raw) { fill($0.bindMemory(to: UInt8.self).baseAddress!) }
        return rc == 0 ? UUID(uuid: raw) : nil
    }

    public static func resolve(user name: String) -> ACLPrincipal? {
        var pw = passwd(), result: UnsafeMutablePointer<passwd>?
        var buf = [CChar](repeating: 0, count: 4096)
        guard getpwnam_r(name, &pw, &buf, buf.count, &result) == 0, result != nil else { return nil }
        let uid = pw.pw_uid
        return uuid { mbr_uid_to_uuid(uid, $0) }.map { .user(name: name, uuid: $0) }
    }

    public static func resolve(group name: String) -> ACLPrincipal? {
        if name == everyone.name { return everyone }
        var gr = group(), result: UnsafeMutablePointer<group>?
        var buf = [CChar](repeating: 0, count: 65_536)
        guard getgrnam_r(name, &gr, &buf, buf.count, &result) == 0, result != nil else { return nil }
        let gid = gr.gr_gid
        return uuid { mbr_gid_to_uuid(gid, $0) }.map { .group(name: name, uuid: $0) }
    }

    /// For a UUID read from an ACL entry. Unknown UUIDs keep their UUID string as the name (as a user), so an
    /// orphaned entry is still shown and written back unchanged (writing uses only the UUID).
    static func principal(for uuid: UUID) -> ACLPrincipal {
        if uuid == everyone.uuid { return everyone }
        var raw = uuid.uuid
        var id: id_t = 0, type: Int32 = 0
        let rc = withUnsafeBytes(of: &raw) { mbr_uuid_to_id($0.bindMemory(to: UInt8.self).baseAddress!, &id, &type) }
        if rc == 0 && type == ID_TYPE_UID {
            var pw = passwd(), result: UnsafeMutablePointer<passwd>?
            var buf = [CChar](repeating: 0, count: 4096)
            if getpwuid_r(id, &pw, &buf, buf.count, &result) == 0, result != nil, let n = pw.pw_name {
                return .user(name: String(cString: n), uuid: uuid)
            }
        } else if rc == 0 && type == ID_TYPE_GID {
            var gr = group(), result: UnsafeMutablePointer<group>?
            var buf = [CChar](repeating: 0, count: 65_536)
            if getgrgid_r(id, &gr, &buf, buf.count, &result) == 0, result != nil, let n = gr.gr_name {
                return .group(name: String(cString: n), uuid: uuid)
            }
        }
        return .user(name: uuid.uuidString, uuid: uuid)
    }

    /// Users with uid ≥ 500 (sorted by name), then `everyone` and the groups not starting with "_" (sorted by name).
    public static func all(lanes: LanePool) async -> [ACLPrincipal] {
        (try? await lanes.perform(on: .unknown, .read) { _ in
            allLock.withLock {
                var userNames: Set<String> = [], groupNames: Set<String> = []
                setpwent()
                while let p = getpwent() {
                    if p.pointee.pw_uid >= 500, let n = p.pointee.pw_name { userNames.insert(String(cString: n)) }
                }
                endpwent()
                setgrent()
                while let g = getgrent() {
                    if let c = g.pointee.gr_name, case let n = String(cString: c), !n.hasPrefix("_") { groupNames.insert(n) }
                }
                endgrent()
                let users = userNames.sorted().compactMap { resolve(user: $0) }
                let groups = groupNames.subtracting([everyone.name]).sorted().compactMap { resolve(group: $0) }
                return users + [everyone] + groups
            }
        }) ?? [everyone]
    }
    private static let allLock = NSLock()      // getpwent/getgrent iterate shared state and are not reentrant
}
