import Foundation
import Synchronization

public struct MetadataItem: Sendable, Equatable, Codable {
    public var path: String
    public var name: String
    public var size: Int64?
    public var modified: Date?
    public var created: Date?
    public var contentTypeTree: [String]
    public var isInvisible: Bool
    public init(path: String, name: String, size: Int64?, modified: Date?, created: Date?, contentTypeTree: [String], isInvisible: Bool) {
        self.path = path; self.name = name; self.size = size; self.modified = modified; self.created = created
        self.contentTypeTree = contentTypeTree; self.isInvisible = isInvisible
    }
}

public enum MetadataQueryEvent: Sendable, Equatable { case added([MetadataItem]), updated([MetadataItem]), removed([String]), gatheringFinished, failed }

public protocol MetadataQuerying: Sendable {
    /// One live query per call; cancelling iteration stops it.
    func run(_ request: SpotlightRequest) -> AsyncStream<MetadataQueryEvent>
}

/// Scripted Spotlight for tests and sandboxed app runs (no index access at all).
public final class FakeMetadataQuery: MetadataQuerying {
    public struct Step: Sendable {
        public var delay: Duration
        public var event: MetadataQueryEvent
        public init(delay: Duration = .zero, _ event: MetadataQueryEvent) { self.delay = delay; self.event = event }
    }
    private struct State { var runs: [[Step]]; var count = 0; var requests: [SpotlightRequest] = [] }
    private let state: Mutex<State>

    public init(runs: [[Step]]) { state = Mutex(State(runs: runs)) }
    public convenience init(items: [MetadataItem]) { self.init(runs: [[Step(.added(items)), Step(.gatheringFinished)]]) }

    public func setRuns(_ runs: [[Step]]) { state.withLock { $0.runs = runs; $0.count = 0 } }
    public func requests() -> [SpotlightRequest] { state.withLock { $0.requests } }

    public func run(_ request: SpotlightRequest) -> AsyncStream<MetadataQueryEvent> {
        let steps: [Step] = state.withLock { s in
            s.requests.append(request)
            defer { s.count += 1 }
            return s.runs.isEmpty ? [Step(.gatheringFinished)] : s.runs[min(s.count, s.runs.count - 1)]
        }
        let (stream, continuation) = AsyncStream.makeStream(of: MetadataQueryEvent.self, bufferingPolicy: .unbounded)
        let task = Task {
            for step in steps {
                if step.delay > .zero { try? await Task.sleep(for: step.delay) }
                if Task.isCancelled { break }
                continuation.yield(step.event)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}
