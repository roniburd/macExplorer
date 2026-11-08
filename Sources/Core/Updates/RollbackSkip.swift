import Foundation

/// Recorded just before MacExplorer quits to swap in an older build; read once by the next launch.
public struct PendingRollback: Sendable, Equatable, Codable {
    /// The build being installed.
    public var targetBuild: Int
    /// The build that was running when the rollback started (the skip ceiling).
    public var fromBuild: Int
    /// Where the swap helper moves the replaced app (trashed by the next launch).
    public var backupPath: String

    public init(targetBuild: Int, fromBuild: Int, backupPath: String) {
        self.targetBuild = targetBuild
        self.fromBuild = fromBuild
        self.backupPath = backupPath
    }
}

/// "Skip until newer" (owner decision 2026-11-08): after a rollback, background checks skip every build up to the
/// one rolled back from; anything published later is offered as usual.
public enum RollbackSkip {
    public struct Reconciled: Equatable, Sendable {
        /// The new skip ceiling; nil = leave the stored one unchanged.
        public var skipThrough: Int?
        /// The replaced app to move to the Trash, if the swap happened.
        public var trashBackup: String?
    }

    /// The first launch after a rollback attempt. Running as the target: the swap worked, skip through `fromBuild`.
    /// Anything else (the helper restored the original, or the user reinstalled): no new skip.
    public static func reconcile(_ pending: PendingRollback, installedBuild: Int?) -> Reconciled {
        guard installedBuild == pending.targetBuild else { return Reconciled(skipThrough: nil, trashBackup: nil) }
        return Reconciled(skipThrough: pending.fromBuild, trashBackup: pending.backupPath)
    }

    public static func shouldSkip(build: Int?, skipThrough: Int?) -> Bool {
        guard let build, let skipThrough else { return false }
        return build <= skipThrough
    }
}
