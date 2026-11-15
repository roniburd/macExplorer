import CFSKit
import Darwin
import Foundation

func openDirectory(_ directory: URL) throws(ReadFailure) -> Int32 {
    let fd = open(directory.path(percentEncoded: false), O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard fd >= 0 else { throw ReadFailure(code: errno, stage: .open) }
    return fd
}

public enum BulkReader {
    /// One getattrlistbulk call: `cfsk_bulk_read` in production, a corrupting wrapper in tests.
    typealias BulkRead = (Int32, UnsafeMutableRawPointer, Int) -> Int32

    /// Reads `directory`, calling `emit` per batch (size/interval from options). Throws ReadFailure.
    /// Returns false from `emit` to stop early. Falls back to FallbackReader on ENOTSUP/EINVAL.
    /// A malformed record (CFSK_NEXT_TRUNCATED: the rest of that buffer is unusable and its entries are lost) falls
    /// back to FallbackReader too while no batch has been emitted; after that it throws a `.truncatedRecords` failure,
    /// never a short listing reported as complete: the caller re-reads with `ReadOptions.forceFallback`.
    public static func read(_ directory: URL, generation: Generation, options: ReadOptions,
                            types: TypeRegistry, context: LaneContext,
                            emit: (Batch) -> Bool) throws(ReadFailure) -> ReadSummary {
        try read(directory, generation: generation, options: options, types: types, context: context,
                 bulkRead: { cfsk_bulk_read($0, $1, $2) }, emit: emit)
    }

    static func read(_ directory: URL, generation: Generation, options: ReadOptions,
                     types: TypeRegistry, context: LaneContext, bulkRead: BulkRead,
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
                do throws(ReadFailure) {
                    return .success(try read(directory, generation: generation, options: inner, types: types, context: context,
                                             bulkRead: bulkRead, emit: emit))
                }
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
        var converter = RecordConverter(types: types, directoryFD: fd)
        var accumulator = BatchAccumulator(batchSize: options.batchSize, interval: options.batchInterval)
        var batch = Batch(generation: generation)
        var total = 0, degraded = 0
        var stopped = false, emitted = false

        reading: while !stopped {
            let n = bulkRead(fd, buffer, size)
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
                if rc == CFSK_NEXT_END { break }
                if rc == CFSK_NEXT_TRUNCATED {
                    // The directory offset is already past this buffer's remaining entries: they can't be re-read.
                    if !emitted {
                        return try FallbackReader.read(directory, generation: generation, options: options, types: types,
                                                       context: context, emit: emit)
                    }
                    throw ReadFailure(code: EIO, stage: .truncatedRecords)
                }
                if rc == CFSK_NEXT_DROPPED { continue }
                let r = converter.append(record, to: &batch, directoriesOnly: options.directoriesOnly)
                if r.appended { total += 1 }
                if r.degraded { degraded += 1 }
                if accumulator.shouldFlush(count: batch.count) {
                    if context.isCancelled { stopped = true; break reading }
                    emitted = true
                    if !emit(batch) { stopped = true; break reading }
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
