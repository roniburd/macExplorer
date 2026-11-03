import CFSKit
import Darwin
import Foundation

public enum FallbackReader {
    public static func read(_ directory: URL, generation: Generation, options: ReadOptions,
                            types: TypeRegistry, context: LaneContext,
                            emit: (Batch) -> Bool) throws(ReadFailure) -> ReadSummary {
        assertOffMain()
        let start = ContinuousClock.now
        let fd = try openDirectory(directory)
        let listFD = dup(fd)
        defer { close(fd) }
        guard listFD >= 0 else { throw ReadFailure(code: errno, stage: .open) }
        guard let dir = fdopendir(listFD) else {
            let code = errno
            close(listFD)
            throw ReadFailure(code: code, stage: .open)
        }
        defer { closedir(dir) }
        var converter = RecordConverter(types: types)
        var accumulator = BatchAccumulator(batchSize: options.batchSize, interval: options.batchInterval)
        var batch = Batch(generation: generation)
        var buffer = [UInt8](repeating: 0, count: 2048)
        var total = 0, degraded = 0, stopped = false
        while true {
            context.heartbeat()       // per entry: directoriesOnly reads of file-only folders may never flush a batch
            errno = 0
            guard let dent = readdir(dir) else {
                if errno != 0 { throw ReadFailure(code: errno, stage: .read) }
                break
            }
            // Raw dirent bytes, NUL-terminated: never re-encode (SMB/NFS/FAT names may not be valid UTF-8).
            var cName = withUnsafeBytes(of: dent.pointee.d_name) { raw in
                Array(raw.prefix(Int(dent.pointee.d_namlen)).bindMemory(to: CChar.self))
            }
            let name = cName.map { UInt8(bitPattern: $0) }
            if name == [0x2E] || name == [0x2E, 0x2E] { continue }
            cName.append(0)
            var record = cfsk_record()
            let rc = cName.withUnsafeBufferPointer { nb -> Int32 in
                buffer.withUnsafeMutableBytes { cfsk_stat_at(fd, nb.baseAddress, $0.baseAddress, $0.count, &record) }
            }
            if rc != 0 {
                let code = errno
                if code == ENOENT { continue }      // vanished between readdir and stat
                // Degraded row: name + d_type only, errno in the side table (§4.2 rule 3).
                var fake = cfsk_record()
                // d_ino is the inode = ATTR_CMN_FILEID, so degraded rows keep distinct object identities.
                fake.fields = CFSK_HAS_NAME | CFSK_HAS_ERROR | CFSK_HAS_OBJTYPE | CFSK_HAS_FILEID
                fake.error = UInt32(bitPattern: code)
                fake.file_id = UInt64(dent.pointee.d_ino)
                fake.obj_type = dent.pointee.d_type == DT_DIR ? RecordConverter.VDIR : dent.pointee.d_type == DT_LNK ? RecordConverter.VLNK : RecordConverter.VREG
                fake.name_len = UInt32(name.count)
                let r = name.withUnsafeBufferPointer { nb -> (appended: Bool, degraded: Bool) in
                    fake.name = UnsafeRawPointer(nb.baseAddress!).assumingMemoryBound(to: CChar.self)
                    return converter.append(fake, to: &batch, directoriesOnly: options.directoriesOnly)
                }
                if r.appended { total += 1; degraded += 1 }
            } else {
                // record.name points into `buffer`; still valid here.
                let r = buffer.withUnsafeBytes { _ in converter.append(record, to: &batch, directoriesOnly: options.directoriesOnly) }
                if r.appended { total += 1 }
                if r.degraded { degraded += 1 }
            }
            if accumulator.shouldFlush(count: batch.count) {
                if context.isCancelled || !emit(batch) { stopped = true; break }
                batch = Batch(generation: generation)
            }
        }
        if !stopped && batch.count > 0 { _ = emit(batch) }
        return ReadSummary(entryCount: total, degradedCount: degraded, usedFallback: true, elapsed: ContinuousClock.now - start)
    }
}
