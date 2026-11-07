import Foundation
import MacxFixtures

/// The ONLY file in macx-bench that names MacxFixtures (P1-02) types. If P1-02's names differ from the
/// ones used here, adapt this file only (Contract note C1).
struct SandboxHandle: Sendable {
    fileprivate let sandbox: Sandbox
    var root: URL { sandbox.root }
    static func make(prefix: String) throws -> SandboxHandle { SandboxHandle(sandbox: try Sandbox(prefix: prefix)) }
    /// Creates the file, or replaces its contents if it already exists (Sandbox.createFile is O_EXCL).
    @discardableResult func file(_ relative: String, _ contents: Data = Data("x".utf8)) -> URL {
        fixtureWrite(relative) {
            let url = sandbox.url(relative)
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                try sandbox.overwrite(relative, contents: contents)
                return url
            }
            return try sandbox.createFile(relative, contents: contents)
        }
    }
    @discardableResult func flat(_ relative: String, count: Int) -> URL {
        fixtureWrite(relative) { try FixtureTree.flat(in: sandbox, at: relative, count: count) }
    }
    /// P2-20: `folders` directories "d<n>" under `relative`, each holding `filesPerFolder` files "f<n>" of `bytes` bytes.
    @discardableResult func folders(_ relative: String, folders: Int, filesPerFolder: Int, bytes: Int) -> URL {
        fixtureWrite(relative) {
            let root = try sandbox.createDirectory(relative)
            let contents = Data(count: bytes)
            for d in 0..<folders {
                try sandbox.createDirectory("\(relative)/d\(d)")
                for f in 0..<filesPerFolder { try sandbox.createFile("\(relative)/d\(d)/f\(f)", contents: contents) }
            }
            return root
        }
    }
    /// P3-13: FixtureTree.deep — `depth` levels, `breadth` folders "d<n>" and `filesPerDir` files "f<n>.txt" per folder.
    @discardableResult func deep(_ relative: String, depth: Int, breadth: Int, filesPerDir: Int) -> URL {
        fixtureWrite(relative) { try FixtureTree.deep(in: sandbox, at: relative, depth: depth, breadth: breadth, filesPerDir: filesPerDir) }
    }
    /// P2-20: Finder tags through the guarded fixture writer (refuses paths outside the sandbox).
    func finderTags(_ tags: [String], on relative: String) {
        fixtureWrite(relative) { try sandbox.setFinderTags(tags, on: relative) }
    }
    func destroy() { sandbox.destroy() }
}

/// A fixture write inside a fresh sandbox only fails when the environment is broken (disk full,
/// unwritable TMPDIR); the bench cannot measure anything then, so it stops with the reason.
func fixtureWrite<T>(_ relative: String, _ body: () throws -> T) -> T {
    do { return try body() } catch { preconditionFailure("fixture write '\(relative)' failed: \(error)") }
}
