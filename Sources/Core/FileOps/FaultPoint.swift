/// Test-only fault injection points; `FileOpTuning.faultHook` is called synchronously at each (on a lane or in job code).
public enum FaultPoint: String, Sendable, CaseIterable {
    case afterPartialCopy, beforePartialRename, afterTrashDestination, beforeSourceDelete, midCopyChunk, afterFirstItem
}
