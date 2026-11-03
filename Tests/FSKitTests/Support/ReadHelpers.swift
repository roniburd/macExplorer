import Foundation
import MacxFS

/// Runs BulkReader (or FallbackReader) synchronously on a lane and returns name → (entry, errno).
func readAll(_ dir: URL, options: ReadOptions = ReadOptions(), lanes: LanePool = LanePool(),
             types: TypeRegistry = .shared) async throws -> (entries: [String: (Entry, Int32?)], summary: ReadSummary, batches: [Int]) {
    try await lanes.perform(on: .unknown) { ctx in
        var entries: [String: (Entry, Int32?)] = [:]
        var sizes: [Int] = []
        let summary = try BulkReader.read(dir, generation: .initial, options: options, types: types, context: ctx) { batch in
            sizes.append(batch.count)
            let errs = Dictionary(uniqueKeysWithValues: batch.errors.map { ($0.index, $0.code) })
            for i in 0..<batch.count { entries[batch.name(at: i)] = (batch.entries[i], errs[UInt32(i)]) }
            return true
        }
        return (entries, summary, sizes)
    }
}

/// Collects a DirectoryReader stream.
func collect(_ stream: AsyncStream<ReadEvent>) async -> (batches: [Batch], others: [String]) {
    var batches: [Batch] = [], others: [String] = []
    for await event in stream {
        switch event {
        case .batch(let b): batches.append(b)
        case .stalled: others.append("stalled")
        case .waitingForPermission: others.append("waiting")
        case .resumed: others.append("resumed")
        case .completed(let s): others.append("completed:\(s.entryCount)")
        case .failed(let f): others.append("failed:\(f.code):\(f.stage)")
        }
    }
    return (batches, others)
}
