import CFSKit

/// Runs body synchronously on the current (lane) thread with dataless materialization off; restores the
/// previous policy afterwards. Never contains a suspension point. Call only from lane work.
public func withNoMaterialization<T>(_ body: () throws -> T) rethrows -> T {
    var previous: Int32 = 0
    let changed = cfsk_materialize_off(&previous) == 0
    defer { if changed { _ = cfsk_materialize_restore(previous) } }
    return try body()
}
