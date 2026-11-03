import Foundation
import MacxFS

public enum PasteOperation: Sendable, Equatable { case copy, move }

public struct PastePlan: Sendable, Equatable {
    public var sources: [URL]
    public var destination: URL
    public var operation: PasteOperation
    public var isNoOp: Bool                           // cut-paste into the items' own folder: do nothing, clear cut

    public init(sources: [URL], destination: URL, operation: PasteOperation, isNoOp: Bool) {
        self.sources = sources
        self.destination = destination
        self.operation = operation
        self.isNoOp = isNoOp
    }
}

/// Copy / cut / paste planning (§5.6). The cut marker counts only while the pasteboard's changeCount still equals the
/// value recorded at cut time in this process, so a paste never moves items the user can't see marked as cut.
@MainActor
public final class Clipboard {
    public let backend: any PasteboardBackend
    private var cutSet: Set<URL> = []
    private var cutChangeCount: Int?
    private let observers = Observers<Void>()

    public init(backend: any PasteboardBackend) {
        self.backend = backend
    }

    public func copy(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        backend.writeFileURLs(urls, cutMarker: false)
        resetCut()
    }

    public func cut(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        cutChangeCount = backend.writeFileURLs(urls, cutMarker: true)
        cutSet = Set(urls)
        observers.send(())
    }

    /// Valid only while backend.changeCount == the count recorded at cut time, in this process.
    public var cutURLs: Set<URL> { isCutValid ? cutSet : [] }

    /// Names of cut items directly inside `directory` (views dim these rows).
    public func cutNames(in directory: URL) -> Set<String> {
        guard isCutValid else { return [] }
        let dir = LexicalPath.standardize(directory)
        var names: Set<String> = []
        for url in cutSet {
            let path = LexicalPath.standardize(url)
            guard path != "/", LexicalPath.same(LexicalPath.parent(of: path), dir) else { continue }
            names.insert(url.lastPathComponent)
        }
        return names
    }

    /// On app activation and after every command: drops a cut whose changeCount moved on.
    public func revalidate() {
        if cutChangeCount != nil, !isCutValid { resetCut() }
    }

    /// Esc: rewrite the URLs without the marker, so dimming and move-on-paste agree. Leaves other apps' contents alone.
    public func clearCut() {
        if isCutValid, backend.hasCutMarker() {
            backend.writeFileURLs(backend.readFileURLs(), cutMarker: false)
        }
        resetCut()
    }

    public var canPaste: Bool { backend.hasFileURLs() }

    /// moveItemHere: ⌥⌘V (move whatever file URLs are present). Returns nil when nothing pasteable.
    public func pastePlan(into folder: URL, moveItemHere: Bool) -> PastePlan? {
        let sources = backend.readFileURLs()
        guard !sources.isEmpty else { return nil }
        let operation: PasteOperation = moveItemHere || (isCutValid && backend.hasCutMarker()) ? .move : .copy
        var isNoOp = false
        if operation == .move {
            let destination = LexicalPath.standardize(folder)
            isNoOp = sources.allSatisfy { LexicalPath.same(LexicalPath.parent(of: LexicalPath.standardize($0)), destination) }
        }
        return PastePlan(sources: sources, destination: folder, operation: operation, isNoOp: isNoOp)
    }

    /// Move done (or no-op cut-paste) → clear cut state. A finished copy leaves the cut state alone.
    public func didPaste(_ plan: PastePlan) {
        guard plan.operation == .move else { return }
        resetCut()
    }

    /// Fires when the cut set changed.
    public func observe(_ handler: @escaping @MainActor () -> Void) -> ObserverToken {
        observers.add { _ in handler() }
    }

    private var isCutValid: Bool {
        guard let recorded = cutChangeCount else { return false }
        return recorded == backend.changeCount
    }

    private func resetCut() {
        guard cutChangeCount != nil else { return }
        cutChangeCount = nil
        cutSet = []
        observers.send(())
    }
}
