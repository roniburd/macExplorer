import Foundation
import Core

/// Sandbox mode (--root): sidebar rows must never point outside the root, so one click can't take a sandboxed run
/// (scenario, test, manual check) onto real folders. Without a root everything is allowed. Pure path checks.
struct SandboxConfinement: Sendable {
    let root: URL?

    func allows(_ url: URL) -> Bool {
        guard let root else { return true }
        let r = ChangeBus.key(for: root), u = ChangeBus.key(for: url)
        return u == r || u.hasPrefix(r == "/" ? r : r + "/")
    }
}
