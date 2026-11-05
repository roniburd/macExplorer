import Foundation
import MacxFS

/// Folder sizes by identity (object id on idStable volumes, path elsewhere) and the folder's own mtime (§11 Phase 2).
/// An LRU of `capacity` entries. Paths are stored in `ChangeBus.key` form (lexical, /private/var ≡ /var) so
/// ancestor invalidation compares one spelling. Main actor only: no file-system access.
@MainActor
public final class FolderSizeCache {
    private struct Slot { var size: FolderSize; var mtime: Int64; var path: String; var used: UInt64 }
    private var slots: [FolderSizeIdentity: Slot] = [:]
    private var clock: UInt64 = 0
    private let capacity: Int

    public init(capacity: Int = 20_000) { self.capacity = max(1, capacity) }

    public var count: Int { slots.count }

    /// nil when absent or recorded for a different mtime.
    public func value(for key: FolderSizeKey) -> FolderSize? {
        guard var slot = slots[key.identity], slot.mtime == key.mtime else { return nil }
        clock += 1
        slot.used = clock
        slots[key.identity] = slot
        return slot.size
    }

    public func store(_ size: FolderSize, for key: FolderSizeKey, path: String) {
        clock += 1
        slots[key.identity] = Slot(size: size, mtime: key.mtime, path: Self.normalize(path), used: clock)
        // O(n) only when over capacity, at most once per stored scan result: negligible next to the scan.
        if slots.count > capacity, let victim = slots.min(by: { $0.value.used < $1.value.used })?.key {
            slots[victim] = nil
        }
    }

    public func invalidate(_ identity: FolderSizeIdentity) { slots[identity] = nil }

    /// Drops entries whose path is `path` or one of its ancestors (component-wise: "/a/bc" is not under "/a/b").
    public func invalidateAncestors(ofDirectory path: String) {
        let dir = Self.normalize(path)
        for (id, slot) in slots where slot.path == dir || dir.hasPrefix(slot.path == "/" ? "/" : slot.path + "/") {
            slots[id] = nil
        }
    }

    nonisolated static func normalize(_ path: String) -> String { ChangeBus.key(for: URL(filePath: path)) }
}
