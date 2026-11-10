import Foundation
import Darwin
import MacxFS

/// A failed ACL call, as an errno.
public struct ACLIOError: Error, Sendable, Equatable, ErrnoCarrying {
    public var code: Int32
    public init(code: Int32) { self.code = code }
    var errnoCode: Int32 { code }
}

/// Reads and writes an item's extended ACL (`ACL_TYPE_EXTENDED`) with the `acl_*_link_np` calls, so a symbolic
/// link's own ACL is used, never its target's. Lane only: every call does file-system I/O.
public enum ACLIO {
    /// The item's entries in on-disk order. No ACL → `[]`; a missing item throws ENOENT.
    public static func read(_ url: URL) throws(ACLIOError) -> [ACLEntry] {
        assertOffMain()
        let acl = try get(url)
        guard let acl else { return [] }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var out: [ACLEntry] = []
        var entry: acl_entry_t?
        var which = ACL_FIRST_ENTRY.rawValue
        while acl_get_entry(acl, which, &entry) == 0, let e = entry {
            which = ACL_NEXT_ENTRY.rawValue
            var tag = ACL_UNDEFINED_TAG
            guard acl_get_tag_type(e, &tag) == 0, tag == ACL_EXTENDED_ALLOW || tag == ACL_EXTENDED_DENY,
                  let q = acl_get_qualifier(e) else { continue }
            let uuid = UUID(uuid: q.assumingMemoryBound(to: uuid_t.self).pointee)
            acl_free(q)
            var permset: acl_permset_t?
            var perms: ACLPermissions = []
            if acl_get_permset(e, &permset) == 0, let permset {
                for (p, d) in ACLPermissions.all where acl_get_perm_np(permset, d) == 1 { perms.insert(p) }
            }
            var flagset: acl_flagset_t?
            var inheritance: ACLInheritance = []
            var inherited = false
            if acl_get_flagset_np(UnsafeMutableRawPointer(e), &flagset) == 0, let flagset {
                for (i, f) in ACLInheritance.all where acl_get_flag_np(flagset, f) == 1 { inheritance.insert(i) }
                inherited = acl_get_flag_np(flagset, ACL_ENTRY_INHERITED) == 1
            }
            out.append(ACLEntry(kind: tag == ACL_EXTENDED_DENY ? .deny : .allow, principal: PrincipalDirectory.principal(for: uuid),
                                permissions: perms, inheritance: inheritance, isInherited: inherited))
        }
        return out
    }

    /// Writes `explicit` (their `isInherited` is ignored) in canonical order, followed by the item's current
    /// inherited entries unchanged.
    public static func write(explicit: [ACLEntry], to url: URL) throws(ACLIOError) {
        assertOffMain()
        let inherited = try read(url).filter(\.isInherited)
        let ordered = canonicalOrder(explicit.map { var e = $0; e.isInherited = false; return e }) + inherited
        // acl_create_entry may reallocate the ACL, so the variable (not the first pointer) is freed.
        var acl: acl_t? = acl_init(Int32(max(ordered.count, 1)))
        guard let initial = acl else { throw ACLIOError(code: errno) }
        defer { acl_free(UnsafeMutableRawPointer(acl ?? initial)) }
        for e in ordered {
            var entry: acl_entry_t?
            guard acl_create_entry(&acl, &entry) == 0, let entry else { throw ACLIOError(code: errno) }
            guard acl_set_tag_type(entry, e.kind == .deny ? ACL_EXTENDED_DENY : ACL_EXTENDED_ALLOW) == 0 else { throw ACLIOError(code: errno) }
            var u = e.principal.uuid.uuid
            guard withUnsafeBytes(of: &u, { acl_set_qualifier(entry, $0.baseAddress) }) == 0 else { throw ACLIOError(code: errno) }
            var permset: acl_permset_t?
            guard acl_get_permset(entry, &permset) == 0, let permset else { throw ACLIOError(code: errno) }
            acl_clear_perms(permset)
            for (p, d) in ACLPermissions.all where e.permissions.contains(p) { acl_add_perm(permset, d) }
            guard acl_set_permset(entry, permset) == 0 else { throw ACLIOError(code: errno) }
            var flagset: acl_flagset_t?
            guard acl_get_flagset_np(UnsafeMutableRawPointer(entry), &flagset) == 0, let flagset else { throw ACLIOError(code: errno) }
            acl_clear_flags_np(flagset)
            for (i, f) in ACLInheritance.all where e.inheritance.contains(i) { acl_add_flag_np(flagset, f) }
            if e.isInherited { acl_add_flag_np(flagset, ACL_ENTRY_INHERITED) }
            guard acl_set_flagset_np(UnsafeMutableRawPointer(entry), flagset) == 0 else { throw ACLIOError(code: errno) }
        }
        try set(acl ?? initial, on: url)
    }

    /// `acl_to_text` form, used to snapshot for undo; "" when the item has no entries.
    public static func text(_ url: URL) throws(ACLIOError) -> String {
        assertOffMain()
        guard let acl = try get(url) else { return "" }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var probe: acl_entry_t?
        guard acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &probe) == 0 else { return "" }
        var len = 0
        guard let t = acl_to_text(acl, &len) else { throw ACLIOError(code: errno) }
        defer { acl_free(UnsafeMutableRawPointer(t)) }
        return String(cString: t)
    }

    /// Sets the ACL from `text` (the `text(_:)` form); "" removes every entry.
    public static func restore(text: String, to url: URL) throws(ACLIOError) {
        assertOffMain()
        let acl: acl_t? = text.isEmpty ? acl_init(1) : acl_from_text(text)
        guard let acl else { throw ACLIOError(code: EINVAL) }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        try set(acl, on: url)
    }

    /// Explicit deny, then explicit allow, then inherited entries; order within each group kept.
    public static func canonicalOrder(_ entries: [ACLEntry]) -> [ACLEntry] {
        let explicit = entries.filter { !$0.isInherited }
        return explicit.filter { $0.kind == .deny } + explicit.filter { $0.kind == .allow } + entries.filter(\.isInherited)
    }

    // MARK: -

    /// nil = the item exists and has no ACL. `acl_get_link_np` reports both "no ACL" and "no item" as ENOENT;
    /// an lstat tells them apart.
    private static func get(_ url: URL) throws(ACLIOError) -> acl_t? {
        if let acl = acl_get_link_np(url.path, ACL_TYPE_EXTENDED) { return acl }
        let code = errno
        if code == ENOENT {
            var st = stat()
            if lstat(url.path, &st) == 0 { return nil }
        }
        throw ACLIOError(code: code)
    }

    /// When an entry denies the owner `readsecurity`, `acl_set_link_np` fails with EACCES: it lstats the item
    /// first, and that lstat is denied, although the owner may still change the ACL. Symbolic links never carry
    /// such an entry (their lstat isn't denied), so when readlink confirms the item isn't one, `acl_set_file` sets
    /// it the way `acl_set_link_np` would have. So such an ACL can still be rolled back, undone or cleared.
    private static func set(_ acl: acl_t, on url: URL) throws(ACLIOError) {
        let path = url.path
        guard acl_set_link_np(path, ACL_TYPE_EXTENDED, acl) != 0 else { return }
        let code = errno
        guard code == EACCES else { throw ACLIOError(code: code) }
        var byte: CChar = 0
        guard readlink(path, &byte, 1) < 0, errno == EINVAL else { throw ACLIOError(code: code) }
        guard acl_set_file(path, ACL_TYPE_EXTENDED, acl) == 0 else { throw ACLIOError(code: errno) }
    }
}
