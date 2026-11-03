import Foundation
import Synchronization

public struct ItemSummary: Sendable, Equatable {
    public var url: URL
    public var isDirectory: Bool
    public var size: Int64
    public var modified: Date
    public init(url: URL, isDirectory: Bool, size: Int64, modified: Date) {
        self.url = url; self.isDirectory = isDirectory; self.size = size; self.modified = modified
    }
}
public struct ConflictPair: Sendable, Equatable {
    public var source: ItemSummary
    public var destination: ItemSummary
    public init(source: ItemSummary, destination: ItemSummary) { self.source = source; self.destination = destination }
}
public enum ConflictAction: String, Sendable, Codable { case replace, skip, keepBoth, merge }
public struct ConflictInfo: Sendable, Equatable {
    public var pair: ConflictPair
    public var isFolderMerge: Bool
    public var knownRemaining: Int
    public var pendingPairs: [ConflictPair]
    public init(pair: ConflictPair, isFolderMerge: Bool, knownRemaining: Int, pendingPairs: [ConflictPair]) {
        self.pair = pair; self.isFolderMerge = isFolderMerge; self.knownRemaining = knownRemaining; self.pendingPairs = pendingPairs
    }
}
public enum ConflictResolution: Sendable, Equatable {
    case one(ConflictAction)
    case all(ConflictAction)
    case perItem([URL: ConflictAction])
    case cancelJob
}
public struct SpaceShortfall: Sendable, Equatable {
    public var needed: Int64
    public var available: Int64
    public var volumeName: String
    public init(needed: Int64, available: Int64, volumeName: String) { self.needed = needed; self.available = available; self.volumeName = volumeName }
}

public protocol FileOpInteraction: Sendable {
    func resolveConflict(_ conflict: ConflictInfo, job: JobSnapshot) async -> ConflictResolution
    func resolveError(_ error: FileOpError, job: JobSnapshot) async -> ErrorResolution
    func confirmInsufficientSpace(_ shortfall: SpaceShortfall, job: JobSnapshot) async -> Bool
    func confirmPermanentDeleteWithoutTrash(_ urls: [URL], job: JobSnapshot) async -> Bool
}

/// Forwards to a target set later. Calls made before a target exists suspend until `setTarget`.
public final class InteractionProxy: FileOpInteraction {
    private struct State {
        var target: (any FileOpInteraction)?
        var waiters: [CheckedContinuation<any FileOpInteraction, Never>] = []
    }
    private let state = Mutex(State())
    public init() {}

    public func setTarget(_ target: any FileOpInteraction) {
        let waiters = state.withLock { s -> [CheckedContinuation<any FileOpInteraction, Never>] in
            s.target = target
            let w = s.waiters
            s.waiters = []
            return w
        }
        for w in waiters { w.resume(returning: target) }
    }

    private func target() async -> any FileOpInteraction {
        if let t = state.withLock({ $0.target }) { return t }
        return await withCheckedContinuation { (c: CheckedContinuation<any FileOpInteraction, Never>) in
            let ready: (any FileOpInteraction)? = state.withLock { s in
                if let t = s.target { return t }
                s.waiters.append(c)
                return nil
            }
            if let ready { c.resume(returning: ready) }
        }
    }

    public func resolveConflict(_ conflict: ConflictInfo, job: JobSnapshot) async -> ConflictResolution {
        await target().resolveConflict(conflict, job: job)
    }
    public func resolveError(_ error: FileOpError, job: JobSnapshot) async -> ErrorResolution {
        await target().resolveError(error, job: job)
    }
    public func confirmInsufficientSpace(_ shortfall: SpaceShortfall, job: JobSnapshot) async -> Bool {
        await target().confirmInsufficientSpace(shortfall, job: job)
    }
    public func confirmPermanentDeleteWithoutTrash(_ urls: [URL], job: JobSnapshot) async -> Bool {
        await target().confirmPermanentDeleteWithoutTrash(urls, job: job)
    }
}

/// Tests and macx-scenarios: answers from queues (defaults: .one(.skip), .skip, false, false) and records questions.
public final class ScriptedInteraction: FileOpInteraction {
    private struct State {
        var conflicts: [ConflictResolution]; var errors: [ErrorResolution]; var space: [Bool]; var noTrash: [Bool]
        var askedConflicts: [ConflictInfo] = []; var askedErrors: [FileOpError] = []
        var askedSpace: [SpaceShortfall] = []; var askedNoTrash: [[URL]] = []
    }
    private let state: Mutex<State>
    public init(conflicts: [ConflictResolution] = [], errors: [ErrorResolution] = [],
                space: [Bool] = [], noTrash: [Bool] = []) {
        state = Mutex(State(conflicts: conflicts, errors: errors, space: space, noTrash: noTrash))
    }
    public func askedConflicts() -> [ConflictInfo] { state.withLock { $0.askedConflicts } }
    public func askedErrors() -> [FileOpError] { state.withLock { $0.askedErrors } }
    public func askedSpace() -> [SpaceShortfall] { state.withLock { $0.askedSpace } }
    public func askedNoTrash() -> [[URL]] { state.withLock { $0.askedNoTrash } }

    public func resolveConflict(_ conflict: ConflictInfo, job: JobSnapshot) async -> ConflictResolution {
        state.withLock { s in
            s.askedConflicts.append(conflict)
            return s.conflicts.isEmpty ? .one(.skip) : s.conflicts.removeFirst()
        }
    }
    public func resolveError(_ error: FileOpError, job: JobSnapshot) async -> ErrorResolution {
        state.withLock { s in
            s.askedErrors.append(error)
            return s.errors.isEmpty ? .skip : s.errors.removeFirst()
        }
    }
    public func confirmInsufficientSpace(_ shortfall: SpaceShortfall, job: JobSnapshot) async -> Bool {
        state.withLock { s in
            s.askedSpace.append(shortfall)
            return s.space.isEmpty ? false : s.space.removeFirst()
        }
    }
    public func confirmPermanentDeleteWithoutTrash(_ urls: [URL], job: JobSnapshot) async -> Bool {
        state.withLock { s in
            s.askedNoTrash.append(urls)
            return s.noTrash.isEmpty ? false : s.noTrash.removeFirst()
        }
    }
}
