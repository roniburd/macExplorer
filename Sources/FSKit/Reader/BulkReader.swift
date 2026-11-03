import CFSKit
import Darwin
import Foundation

func openDirectory(_ directory: URL) throws(ReadFailure) -> Int32 {
    let fd = open(directory.path(percentEncoded: false), O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard fd >= 0 else { throw ReadFailure(code: errno, stage: .open) }
    return fd
}

public enum BulkReader {
    /// Reads `directory`, calling `emit` per batch (size/interval from options). Throws ReadFailure.
    /// Returns false from `emit` to stop early. Falls back to FallbackReader on ENOTSUP/EINVAL.
    public static func read(_ directory: URL, generation: Generation, options: ReadOptions,
                            types: TypeRegistry, context: LaneContext,
                            emit: (Batch) -> Bool) throws(ReadFailure) -> ReadSummary {
        assertOffMain()
        if options.forceFallback {
            return try FallbackReader.read(directory, generation: generation, options: options, types: types, context: context, emit: emit)
        }
        if options.noMaterialization {
            var inner = options
            inner.noMaterialization = false
            // Result instead of a throwing closure: no typed-throws closure conversion (see DirectoryReader).
            let result: Result<ReadSummary, ReadFailure> = withNoMaterialization {
                do throws(ReadFailure) { return .success(try read(directory, generation: generation, options: inner, types: types, context: context, emit: emit)) }
                catch { return .failure(error) }
            }
            return try result.get()
        }
        let start = ContinuousClock.now
        let fd = try openDirectory(directory)
        defer { close(fd) }
        let size = max(options.bufferSize, 4096)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buffer.deallocate() }
        var converter = RecordConverter(types: types)
        var accumulator = BatchAccumulator(batchSize: options.batchSize, interval: options.batchInterval)
        var batch = Batch(generation: generation)
        var total = 0, degraded = 0
        var stopped = false

        reading: while !stopped {
            let n = cfsk_bulk_read(fd, buffer, size)
            context.heartbeat()
            if n < 0 {
                let code = errno
                if code == EINTR { continue }
                if (code == ENOTSUP || code == EINVAL) && total == 0 && batch.count == 0 {
                    return try FallbackReader.read(directory, generation: generation, options: options, types: types, context: context, emit: emit)
                }
                throw ReadFailure(code: code, stage: .read)
            }
            if n == 0 { break }
            var cursor = cfsk_cursor()
            cfsk_cursor_init(&cursor, buffer, size, UInt32(n))
            var record = cfsk_record()
            while true {
                let rc = cfsk_cursor_next(&cursor, &record)
                if rc == CFSK_NEXT_END || rc == CFSK_NEXT_TRUNCATED { break }
                if rc == CFSK_NEXT_DROPPED { continue }
                let r = converter.append(record, to: &batch, directoriesOnly: options.directoriesOnly)
                if r.appended { total += 1 }
                if r.degraded { degraded += 1 }
                if accumulator.shouldFlush(count: batch.count) {
                    if context.isCancelled || !emit(batch) { stopped = true; break reading }
                    batch = Batch(generation: generation)
                    context.heartbeat()
                }
            }
            if context.isCancelled { stopped = true }
        }
        if !stopped && batch.count > 0 { _ = emit(batch) }
        return ReadSummary(entryCount: total, degradedCount: degraded, usedFallback: false, elapsed: ContinuousClock.now - start)
    }
}
