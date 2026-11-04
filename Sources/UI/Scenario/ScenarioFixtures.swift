import Darwin
import Foundation

enum ScenarioFixtureError: Error, Equatable, CustomStringConvertible {
    case rootNotScenarioSandbox(String)
    case rootNotEmpty(String)
    case unsafePath(String)
    case io(String, Int32)
    case badMode(String)
    var description: String {
        switch self {
        case .rootNotScenarioSandbox(let p): "refusing: --root \(p) is not a macx-scenario-* directory"
        case .rootNotEmpty(let p): "refusing: --root \(p) is not empty"
        case .unsafePath(let p): "refusing unsafe fixture path '\(p)'"
        case .io(let p, let e): "fixture I/O failed for '\(p)' (errno \(e))"
        case .badMode(let p): "bad mode for '\(p)'"
        }
    }
}

enum ScenarioFixtures {
    static let rootPrefix = "macx-scenario-"

    /// Synchronous: call only inside lane work. `root` must already be symlink-resolved. Refuses unless root's
    /// last component starts with "macx-scenario-" and root is empty; every path must stay inside root.
    static func create(_ fixture: ScenarioFile.Fixture, in root: URL) throws(ScenarioFixtureError) {
        guard root.lastPathComponent.hasPrefix(rootPrefix) else { throw .rootNotScenarioSandbox(root.path) }
        let fm = FileManager.default
        let existing: [String]
        do { existing = try fm.contentsOfDirectory(atPath: root.path) } catch { throw .io(root.path, Int32((error as NSError).code)) }
        guard existing.isEmpty else { throw .rootNotEmpty(root.path) }
        let rootPath = root.standardizedFileURL.path

        func target(_ relative: String) throws(ScenarioFixtureError) -> URL {
            guard ScenarioPath.isSafeRelative(relative) else { throw .unsafePath(relative) }
            let url = root.appending(path: relative)
            guard url.standardizedFileURL.path.hasPrefix(rootPath + "/") else { throw .unsafePath(relative) }
            return url
        }

        for dir in fixture.dirs {
            let url = try target(dir)
            do { try fm.createDirectory(at: url, withIntermediateDirectories: true) } catch { throw .io(dir, Int32((error as NSError).code)) }
        }
        let hidden = fixture.hidden ?? []
        for path in fixture.files + hidden {
            let url = try target(path)
            do { try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) } catch {
                throw .io(path, Int32((error as NSError).code))
            }
            let data = fixture.sizes?[path].map { Data(repeating: 0x78, count: $0) } ?? Data("x".utf8)
            guard fm.createFile(atPath: url.path, contents: data) else { throw .io(path, errno) }
            if hidden.contains(path), chflags(url.path, UInt32(UF_HIDDEN)) != 0 { throw .io(path, errno) }
        }
        for (path, mode) in (fixture.modes ?? [:]).sorted(by: { $0.key.count > $1.key.count }) {
            let url = try target(path)
            guard let bits = UInt16(mode, radix: 8) else { throw .badMode(path) }
            if chmod(url.path, mode_t(bits)) != 0 { throw .io(path, errno) }
        }
    }

    /// Names the browser should list in --root once the fixture exists (Show Hidden off).
    static func topLevelVisibleNames(_ fixture: ScenarioFile.Fixture) -> Set<String> {
        let hidden = Set(fixture.hidden ?? [])
        return Set((fixture.files + fixture.dirs).filter { !hidden.contains($0) }
            .compactMap { $0.split(separator: "/").first.map(String.init) }
            .filter { !$0.hasPrefix(".") })
    }
}
