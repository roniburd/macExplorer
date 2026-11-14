// Compiled only by scripts/test-plugin-load.sh, against Packages/MacxPluginKit; not a SwiftPM target.
import Foundation
import MacxPluginKit

final class FixtureProvider: RemoteProvider {
    let id = "test.fixture-plugin"
    let displayName = "Fixture Plugin"
    let iconSymbol = "puzzlepiece"
    func parseAddress(_ text: String) -> RemoteLocation? {
        text.hasPrefix("fixture:") ? RemoteLocation(provider: id, repo: String(text.dropFirst(8))) : nil
    }
    func completions(for text: String) async -> [String] { [] }
    func displayRoot(_ location: RemoteLocation) -> String { location.repo }
    func webURL(_ location: RemoteLocation) -> URL? { nil }
    func listRefs(repo: String) async throws(RemoteError) -> [RemoteRef] { [RemoteRef(name: "main", kind: .branch)] }
    func resolveRef(_ location: RemoteLocation) async throws(RemoteError) -> RemoteLocation { location.withRef(location.ref ?? "main") }
    func list(_ location: RemoteLocation) -> AsyncThrowingStream<[RemoteItem], any Error> {
        AsyncThrowingStream { $0.yield([RemoteItem(name: "hello.txt", kind: .file, size: 5)]); $0.finish() }
    }
    func fetch(_ location: RemoteLocation, item: RemoteItem, to destination: URL) async throws(RemoteError) {
        do { try Data("hello".utf8).write(to: destination) } catch { throw .network("\(error)") }
    }
    func invalidate(repo: String, ref: String?) {}
}

// No @objc rename: a subclass of a library-evolution class is only found by its module-qualified Swift name, so
// the bundle's NSPrincipalClass is "FixturePlugin.FixturePlugin" (spec §5.2, Task 1 spike).
final class FixturePlugin: MacxPlugin {
    override func makeProviders() -> [any RemoteProvider] { [FixtureProvider()] }
}
