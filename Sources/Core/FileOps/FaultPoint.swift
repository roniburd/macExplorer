/// Test-only fault injection points; `FileOpTuning.faultHook` is called synchronously at each (on a lane or in job code).
public enum FaultPoint: String, Sendable, CaseIterable {
    case afterPartialCopy, beforePartialRename, afterTrashDestination, beforeSourceDelete, midCopyChunk, afterFirstItem
    /// chmodRecursive's lane batch, at every cancel checkpoint (every 256 items, starting at 0).
    case modeBatchCheckpoint
    /// A compress (or extract) job's tool was just spawned (on the lane).
    case archiveToolStarted
}
