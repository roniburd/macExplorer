import Foundation
import Darwin

/// The 13 macOS ACL permissions. `rawValue` bit i is the i-th static below (bit 0 = readData), independent of the
/// Darwin `acl_perm_t` values, so the Codable form is stable. For directories the same bits mean list / add file /
/// search / add subdirectory.
public struct ACLPermissions: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let readData = ACLPermissions(rawValue: 1 << 0)            // ACL_READ_DATA = ACL_LIST_DIRECTORY
    public static let writeData = ACLPermissions(rawValue: 1 << 1)           // ACL_WRITE_DATA = ACL_ADD_FILE
    public static let execute = ACLPermissions(rawValue: 1 << 2)             // ACL_EXECUTE = ACL_SEARCH
    public static let delete = ACLPermissions(rawValue: 1 << 3)
    public static let appendData = ACLPermissions(rawValue: 1 << 4)          // ACL_APPEND_DATA = ACL_ADD_SUBDIRECTORY
    public static let deleteChild = ACLPermissions(rawValue: 1 << 5)
    public static let readAttributes = ACLPermissions(rawValue: 1 << 6)
    public static let writeAttributes = ACLPermissions(rawValue: 1 << 7)
    public static let readExtAttributes = ACLPermissions(rawValue: 1 << 8)
    public static let writeExtAttributes = ACLPermissions(rawValue: 1 << 9)
    public static let readSecurity = ACLPermissions(rawValue: 1 << 10)
    public static let writeSecurity = ACLPermissions(rawValue: 1 << 11)
    public static let changeOwner = ACLPermissions(rawValue: 1 << 12)

    public static let readOnlyPreset: ACLPermissions = [.readData, .execute, .readAttributes, .readExtAttributes, .readSecurity]
    public static let readWritePreset: ACLPermissions = readOnlyPreset.union(
        [.writeData, .appendData, .writeAttributes, .writeExtAttributes, .delete, .deleteChild])
    public static let fullControlPreset = ACLPermissions(rawValue: (1 << 13) - 1)

    /// Each permission with its Darwin constant, in bit order.
    static let all: [(ACLPermissions, acl_perm_t)] = [
        (.readData, ACL_READ_DATA), (.writeData, ACL_WRITE_DATA), (.execute, ACL_EXECUTE), (.delete, ACL_DELETE),
        (.appendData, ACL_APPEND_DATA), (.deleteChild, ACL_DELETE_CHILD),
        (.readAttributes, ACL_READ_ATTRIBUTES), (.writeAttributes, ACL_WRITE_ATTRIBUTES),
        (.readExtAttributes, ACL_READ_EXTATTRIBUTES), (.writeExtAttributes, ACL_WRITE_EXTATTRIBUTES),
        (.readSecurity, ACL_READ_SECURITY), (.writeSecurity, ACL_WRITE_SECURITY), (.changeOwner, ACL_CHANGE_OWNER),
    ]
}

/// How an entry propagates to items created inside a folder.
public struct ACLInheritance: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let fileInherit = ACLInheritance(rawValue: 1 << 0)
    public static let directoryInherit = ACLInheritance(rawValue: 1 << 1)
    public static let limitInherit = ACLInheritance(rawValue: 1 << 2)
    public static let onlyInherit = ACLInheritance(rawValue: 1 << 3)

    static let all: [(ACLInheritance, acl_flag_t)] = [
        (.fileInherit, ACL_ENTRY_FILE_INHERIT), (.directoryInherit, ACL_ENTRY_DIRECTORY_INHERIT),
        (.limitInherit, ACL_ENTRY_LIMIT_INHERIT), (.onlyInherit, ACL_ENTRY_ONLY_INHERIT),
    ]
}

/// A user or group an ACL entry applies to. An entry whose UUID no longer resolves keeps the UUID string as its name.
public enum ACLPrincipal: Sendable, Codable, Hashable {
    case user(name: String, uuid: UUID)
    case group(name: String, uuid: UUID)

    public var name: String {
        switch self { case .user(let n, _), .group(let n, _): n }
    }
    public var uuid: UUID {
        switch self { case .user(_, let u), .group(_, let u): u }
    }
}

/// One extended ACL entry.
public struct ACLEntry: Sendable, Codable, Hashable {
    public enum Kind: String, Sendable, Codable { case allow, deny }
    public var kind: Kind
    public var principal: ACLPrincipal
    public var permissions: ACLPermissions
    public var inheritance: ACLInheritance
    /// `ACL_ENTRY_INHERITED`: came from a parent folder; read-only in the editor.
    public var isInherited: Bool
    public init(kind: Kind, principal: ACLPrincipal, permissions: ACLPermissions, inheritance: ACLInheritance = [],
                isInherited: Bool = false) {
        self.kind = kind; self.principal = principal; self.permissions = permissions
        self.inheritance = inheritance; self.isInherited = isInherited
    }
}
