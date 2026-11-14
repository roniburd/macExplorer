import Foundation
import MacxPluginKit

/// The scenario's repository (spec §6 UI scenario): `fake:<repo>[@ref][/path…]` (one-segment repo, as FakeRemoteProvider) over the fixture's in-memory
/// files. Registered only by ScenarioDriver; never shipped behaviour (scenario runs are sandboxed).
struct ScenarioRemoteProvider: RemoteProvider {
    let id = "test.scenario"
    let displayName = "Scenario"
    let iconSymbol = "shippingbox"
    let fixture: ScenarioFile.RemoteFixture

    init(_ fixture: ScenarioFile.RemoteFixture) { self.fixture = fixture }

    func parseAddress(_ text: String) -> RemoteLocation? {
        guard text.hasPrefix("fake:") else { return nil }
        var parts = text.dropFirst(5).split(separator: "/").map(String.init)
        guard var repo = parts.first else { return nil }
        var ref: String?
        if let at = repo.firstIndex(of: "@") { ref = String(repo[repo.index(after: at)...]); repo = String(repo[..<at]) }
        guard repo == fixture.repo, ref?.isEmpty != true else { return nil }
        parts.removeFirst()
        return RemoteLocation(provider: id, repo: repo, ref: ref, path: parts)
    }
    func completions(for text: String) async -> [String] { [] }
    func displayRoot(_ location: RemoteLocation) -> String { location.repo }
    func webURL(_ location: RemoteLocation) -> URL? {
        URL(string: "https://scenario.invalid/\(location.repo)/\(location.ref ?? "main")/\(location.pathString)")
    }
    func listRefs(repo: String) async throws(RemoteError) -> [RemoteRef] {
        fixture.refs.keys.sorted().map { RemoteRef(name: $0, kind: .branch) }
    }
    func resolveRef(_ location: RemoteLocation) async throws(RemoteError) -> RemoteLocation { location.withRef(location.ref ?? "main") }

    func list(_ location: RemoteLocation) -> AsyncThrowingStream<[RemoteItem], any Error> {
        let files = fixture.refs[location.ref ?? "main"] ?? [:]
        let prefix = location.pathString.isEmpty ? "" : location.pathString + "/"
        var items: [String: RemoteItem] = [:]
        for (path, content) in files where path.hasPrefix(prefix) {
            let rest = path.dropFirst(prefix.count).split(separator: "/")
            guard let first = rest.first.map(String.init) else { continue }
            items[first] = rest.count == 1
                ? RemoteItem(name: first, kind: .file, size: Int64(content.utf8.count), contentID: "\(location.ref ?? "main"):\(path)")
                : RemoteItem(name: first, kind: .directory)
        }
        let found = !items.isEmpty || location.path.isEmpty
        return AsyncThrowingStream { c in
            if found { c.yield(items.values.sorted { $0.name < $1.name }); c.finish() } else { c.finish(throwing: RemoteError.notFound) }
        }
    }

    func fetch(_ location: RemoteLocation, item: RemoteItem, to destination: URL) async throws(RemoteError) {
        guard let content = fixture.refs[location.ref ?? "main"]?[location.pathString] else { throw .notFound }
        do { try Data(content.utf8).write(to: destination, options: .withoutOverwriting) } catch { throw .network("\(error)") }
    }
    func invalidate(repo: String, ref: String?) {}
}
