import Foundation
import MacxFS

/// The visible-row extended attribute reads' bookkeeping (FolderModel+Attributes, P2-15): the one read in flight,
/// the latest request made meanwhile, the coalesced refresh, and the invalidation serials. A value owned by one
/// FolderModel and only touched on its actor; the reads themselves, and `attributeTable`, stay in the model.
struct AttributeLoader {
    /// Bumped by every invalidation; a read remembers the serial it began at.
    private(set) var serial = 0
    /// Entries the watcher or a patch invalidated, with the `serial` of that invalidation. They keep their values
    /// (no blank cells) until a read that began after it replaces them.
    var stale: [RowID: Int] = [:]
    /// The one attribute read in flight, and the latest request made meanwhile.
    var task: Task<Void, Never>?
    private(set) var pending: AttributeRequest?
    /// A refresh of the last request is scheduled for the next main-actor turn.
    private(set) var refreshScheduled = false

    /// A new invalidation: returns its serial, to mark the entries it covers.
    mutating func beginInvalidation() -> Int {
        serial += 1
        return serial
    }

    /// A new request: returns it when it can start now, or keeps it (replacing any older one) behind the read in
    /// flight and returns nil.
    mutating func admit(_ request: AttributeRequest) -> AttributeRequest? {
        guard task != nil else { return request }
        pending = request
        return nil
    }

    /// After the read in flight ended (`task` cleared): the request waiting behind it, if any, which may start now.
    mutating func takePending() -> AttributeRequest? {
        defer { pending = nil }
        return pending
    }

    /// Whether a read that began at `readSerial` replaces `id`'s entry (clearing its stale mark): `nil` when the
    /// entry is not stale (the read merges into it), false when it was invalidated after the read began.
    mutating func adopt(_ id: RowID, readSerial: Int) -> Bool? {
        guard let invalidated = stale[id] else { return nil }
        guard invalidated <= readSerial else { return false }
        stale[id] = nil
        return true
    }

    /// Schedules a refresh (callers check `refreshScheduled` first).
    mutating func scheduleRefresh() {
        refreshScheduled = true
    }

    /// The scheduled refresh runs now: false when it was cancelled meanwhile.
    mutating func takeScheduledRefresh() -> Bool {
        guard refreshScheduled else { return false }
        refreshScheduled = false
        return true
    }

    /// Drops the read in flight and the request waiting behind it.
    mutating func cancelRead() {
        task?.cancel()
        task = nil
        pending = nil
    }

    /// A fresh load (start, retry): the read in flight and every stale mark go.
    mutating func reset() {
        cancelRead()
        stale = [:]
    }

    /// Closing: the read in flight, the request waiting behind it and the scheduled refresh go.
    mutating func cancel() {
        cancelRead()
        refreshScheduled = false
    }
}
